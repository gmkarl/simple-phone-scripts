#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, const char ** argv)
{
	int FD = STDIN_FILENO;
	size_t blocksize = 1024*1024;
	uint8_t * buffer = malloc(blocksize+1)+1;
	ssize_t len_read;
	uint64_t in_o = 1;
	if (argc > 1) {
		FD = open(argv[1], 0);
	}
	read(FD, buffer - 1, 1);
	while ((len_read = read(FD, buffer, blocksize))) {
		if ( len_read == -1 ) {
			fprintf( stderr, "Read error\n");
			return len_read;
		}
		uint8_t * ptr = buffer-1;
		uint8_t * ptr2;
		size_t in_len = len_read;
		ssize_t len =  len_read;
		while ((ptr2 = (uint8_t*)memchr(ptr + 1, '\n', len))) {
			if ( ptr2[-1] != '\r' ) {
				fprintf( stderr, "Error, lone \\n found at 0x%0x\n", in_o + (ptr2 - buffer) );
				return 1;
			}
			ssize_t r = write(STDOUT_FILENO, ptr, ptr2 - ptr - 1);
			if (r == -1) {
				fprintf( stderr, "Write error\n");
				return -2;
			} else if (r < ptr2 - ptr - 1) {
				fprintf( stderr, "Short write\n");
				return r;
			}
			len -= ptr2 - ptr;
			ptr = ptr2;
		}
		write(STDOUT_FILENO, ptr, in_len + buffer - ptr - 1);
		buffer[-1] = buffer[in_len - 1];
	}
	write(STDOUT_FILENO, buffer-1, 1);

	return 0;
}
