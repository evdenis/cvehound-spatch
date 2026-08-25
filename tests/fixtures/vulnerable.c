#define FIXTURE_MAX 16

static int table[FIXTURE_MAX];

int fixture_write(unsigned int idx, int value)
{
	table[idx] = value;
	return 0;
}
