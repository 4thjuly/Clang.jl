#define G_URI_RESERVED_CHARS_SUBCOMPONENT_DELIMITERS "!$&'()*+,;="

#define FOO(x, a, b) (a) <= (x) && (x) < (b)
void macro_range(void) {
    int foo = 1;
    int x = 0;
    x = FOO(foo, 1, x);
}

#define EQUALS_A_B (A == B)

#define FOO1 bar1(0x1234)
#define FOO2 (0 \
	| BAR2 \
	| BAR3 \
	| BAR4 \
	| BAR5 \
    )

// #define FOO3(x) BAR6(x)

