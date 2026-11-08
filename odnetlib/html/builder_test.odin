package odnet_html

import "core:strings"
import "core:testing"

@(test)
test_escape_html :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	escape_html(&b, "<script>alert(\"XSS & 'hello'\");</script>")
	result := strings.to_string(b)
	expected := "&lt;script&gt;alert(&quot;XSS &amp; &#39;hello&#39;&quot;);&lt;/script&gt;"

	testing.expect_value(t, result, expected)
}

@(test)
test_escape_string :: proc(t: ^testing.T) {
	res := escape_string("Safe String 123")
	defer delete(res)
	testing.expect_value(t, res, "Safe String 123")
}
