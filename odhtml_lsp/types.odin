package odhtml_lsp

import "core:encoding/json"

Position :: struct {
	line:      int,
	character: int,
}

Range :: struct {
	start: Position,
	end:   Position,
}

Diagnostic_Severity :: enum {
	Error       = 1,
	Warning     = 2,
	Information = 3,
	Hint        = 4,
}

Diagnostic :: struct {
	range:    Range,
	severity: Diagnostic_Severity,
	message:  string,
	source:   string,
}

Prop_Decl :: struct {
	name:          string,
	type_name:     string,
	default_value: string,
	is_required:   bool,
	range:         Range,
	name_range:    Range,
}

Import_Decl :: struct {
	alias: string,
	path:  string,
	range: Range,
}

Node_Kind :: enum {
	Text,
	Interpolation,
	Slot,
	Slot_Block,
	Component_Call,
	If,
	Switch,
	Case,
	For,
	Foreach,
	Tag,
}

Prop_Arg :: struct {
	name:       string,
	value:      string,
	range:      Range,
	name_range: Range,
}

Ast_Node :: struct {
	kind:       Node_Kind,
	name:       string,
	name_range: Range,
	range:      Range,
	props:      [dynamic]Prop_Arg,
	children:   [dynamic]Ast_Node,
	raw_text:   string,
	expr:       string,
	loop_var:   string,
	loop_in:    string,
}

Component_Info :: struct {
	name:        string, // snake_case e.g. "book_card"
	pascal_name: string, // PascalCase e.g. "BookCard"
	file_path:   string,
	uri:         string,
	props:       [dynamic]Prop_Decl,
	imports:     [dynamic]Import_Decl,
	slot_names:  [dynamic]string,
}

Parse_Result :: struct {
	props:           [dynamic]Prop_Decl,
	imports:         [dynamic]Import_Decl,
	nodes:           [dynamic]Ast_Node,
	diagnostics:     [dynamic]Diagnostic,
	component_calls: [dynamic]Ast_Node,
	interpolations:  [dynamic]Ast_Node,
}
