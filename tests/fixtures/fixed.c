#define FIXTURE_MAX 16

static int table[FIXTURE_MAX];

int fixture_write(unsigned int idx, int value)
{
	if (idx >= FIXTURE_MAX)
		return -1;

	table[idx] = value;
	return 0;
}
