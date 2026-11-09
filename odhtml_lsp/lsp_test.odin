package odhtml_lsp

import "core:slice"
import "core:strings"
import "core:testing"

@(test)
test_parser_props_and_imports :: proc(t: ^testing.T) {
	src := `@import "core:fmt"
@import models "../models"
@props(title: string = "Hello", count: int, show: bool = true)

<div>{title}</div>`

	res := parse_template(src)
	defer parse_result_destroy(&res)

	testing.expect_value(t, len(res.imports), 2)
	testing.expect_value(t, res.imports[0].path, "core:fmt")
	testing.expect_value(t, res.imports[1].alias, "models")
	testing.expect_value(t, res.imports[1].path, "../models")

	testing.expect_value(t, len(res.props), 3)
	testing.expect_value(t, res.props[0].name, "title")
	testing.expect_value(t, res.props[0].type_name, "string")
	testing.expect_value(t, res.props[0].default_value, "\"Hello\"")
	testing.expect_value(t, res.props[0].is_required, false)

	testing.expect_value(t, res.props[1].name, "count")
	testing.expect_value(t, res.props[1].type_name, "int")
	testing.expect_value(t, res.props[1].is_required, true)

	testing.expect_value(t, res.props[2].name, "show")
	testing.expect_value(t, res.props[2].type_name, "bool")
	testing.expect_value(t, res.props[2].default_value, "true")
	testing.expect_value(t, res.props[2].is_required, false)

	testing.expect_value(t, len(res.diagnostics), 0)
}

@(test)
test_parser_component_calls_and_slots :: proc(t: ^testing.T) {
	src := `@Card(title: "Overview") {
  <slot:actions>
    <button>Edit</button>
  </slot:actions>
  <p>{slot}</p>
}`

	res := parse_template(src)
	defer parse_result_destroy(&res)

	testing.expect_value(t, len(res.component_calls), 1)
	testing.expect_value(t, res.component_calls[0].name, "Card")
	testing.expect_value(t, len(res.component_calls[0].props), 1)
	testing.expect_value(t, res.component_calls[0].props[0].name, "title")
	testing.expect_value(t, res.component_calls[0].props[0].value, "\"Overview\"")
}

@(test)
test_parser_control_flow :: proc(t: ^testing.T) {
	src := `@if (len(items) > 0) {
  @foreach item, idx in items {
    <span>#{idx}: {item}</span>
  }
} @else {
  <p>Empty</p>
}`

	res := parse_template(src)
	defer parse_result_destroy(&res)

	testing.expect_value(t, len(res.nodes) > 0, true)
	testing.expect_value(t, len(res.diagnostics), 0)
}

@(test)
test_indexer_and_hover :: proc(t: ^testing.T) {
	idx: Indexer
	indexer_init(&idx)
	defer indexer_destroy(&idx)

	book_card_src := `@props(book: Book, show_price: bool = true, index: int = 0)
<div class="card">{book.title}</div>`

	indexer_index_file(&idx, "odnetdemo/books/templates/book_card.odhtml", book_card_src)

	comp, ok := indexer_get_component(&idx, "BookCard")
	testing.expect(t, ok, "BookCard should be found by PascalCase")
	testing.expect_value(t, comp.name, "book_card")
	testing.expect_value(t, len(comp.props), 3)

	comp_snake, ok_snake := indexer_get_component(&idx, "book_card")
	testing.expect(t, ok_snake, "BookCard should be found by snake_case")
	testing.expect_value(t, comp_snake.pascal_name, "BookCard")

	// Test hover on component call
	caller_src := `<div>@BookCard(book: my_book)</div>`
	hover_json := handle_hover(caller_src, Position{line = 0, character = 8}, &idx)
	defer if hover_json != "null" do delete(hover_json)
	testing.expect(t, strings.contains(hover_json, "BookCard"), "Hover should describe BookCard")
	testing.expect(t, strings.contains(hover_json, "show_price"), "Hover should list show_price prop")
}

@(test)
test_definition :: proc(t: ^testing.T) {
	idx: Indexer
	indexer_init(&idx)
	defer indexer_destroy(&idx)

	book_card_src := `@props(book: Book, show_price: bool = true, index: int = 0)
<div class="card">{book.title}</div>`

	indexer_index_file(&idx, "odnetdemo/books/templates/book_card.odhtml", book_card_src)

	caller_src := `@props(active: bool = true)
<div>@BookCard(book: my_book, show_price: true)</div>
<span>{active}</span>`

	// 1. Definition on component name @BookCard
	def_comp := handle_definition(caller_src, Position{line = 1, character = 7}, &idx, "file:///test.odhtml")
	defer if def_comp != "null" do delete(def_comp)
	testing.expect(t, strings.contains(def_comp, "book_card.odhtml"), "Definition on @BookCard should jump to book_card.odhtml")

	// 2. Definition on prop argument show_price
	def_prop := handle_definition(caller_src, Position{line = 1, character = 32}, &idx, "file:///test.odhtml")
	defer if def_prop != "null" do delete(def_prop)
	testing.expect(t, strings.contains(def_prop, "book_card.odhtml"), "Definition on show_price should jump to book_card.odhtml")

	// 3. Definition on template variable active
	def_var := handle_definition(caller_src, Position{line = 2, character = 8}, &idx, "file:///test.odhtml")
	defer if def_var != "null" do delete(def_var)
	testing.expect(t, strings.contains(def_var, "file:///test.odhtml"), "Definition on active should jump to @props in test.odhtml")

	// 4. Definition on Odin type Book in book_card.odhtml -> should jump to books.odin!
	card_uri := path_to_uri("odnetdemo/books/templates/book_card.odhtml")
	defer delete(card_uri)
	def_odin := handle_definition(book_card_src, Position{line = 0, character = 15}, &idx, card_uri)
	defer if def_odin != "null" do delete(def_odin)
	testing.expect(t, strings.contains(def_odin, "books.odin"), "Definition on Book should jump to books.odin")
}
