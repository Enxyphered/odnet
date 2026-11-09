package books

Book :: struct {
	title:         string,
	author:        string,
	price:         f64,
	is_bestseller: bool,
	status:        string,
}

SAMPLE_BOOKS := []Book{
	{
		title = "The Pragmatic Programmer",
		author = "David Thomas & Andrew Hunt",
		price = 49.95,
		is_bestseller = true,
		status = "in_stock",
	},
	{
		title = "Designing Data-Intensive Applications",
		author = "Martin Kleppmann",
		price = 59.99,
		is_bestseller = true,
		status = "in_stock",
	},
	{
		title = "Crafting Interpreters",
		author = "Robert Nystrom",
		price = 45.00,
		is_bestseller = true,
		status = "in_stock",
	},
	{
		title = "Structure and Interpretation of Computer Programs",
		author = "Harold Abelson & Gerald Jay Sussman",
		price = 65.00,
		is_bestseller = false,
		status = "backorder",
	},
	{
		title = "The Odin Programming Language Manual",
		author = "Ginger Bill",
		price = 0.00,
		is_bestseller = true,
		status = "in_stock",
	},
	{
		title = "Operating Systems: Three Easy Pieces",
		author = "Remzi & Andrea Arpaci-Dusseau",
		price = 35.50,
		is_bestseller = false,
		status = "out_of_stock",
	},
}
