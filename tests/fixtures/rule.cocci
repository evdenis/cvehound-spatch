/// The shape of a real CVEhound rule, in miniature: a missing bounds check
/// before an array write, reported by starring the vulnerable line.

virtual detect

@err@
identifier arr, idx;
@@

fixture_write(...)
{
	... when != if (idx >= ...) { ... }
*	arr[idx] = ...;
	...
}
