// libFuzzer harness for capstone's SuperH (SH) disassembler, through the public API only:
// cs_open(CS_ARCH_SH) + cs_disasm_iter with detail on. Byte 0 picks the CPU variant, the rest is code.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <capstone/capstone.h>

int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size);

int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size)
{
	if (Size < 2) {
		return -1;
	}
	if (Size > 0x1000) {
		Size = 0x1000;
	}

	// SH2, SH2A, SH3, SH4, SH4A, then optional FPU, DSP and big endian.
	unsigned int mode = CS_MODE_SH2 << (Data[0] % 5);
	if (Data[0] & 0x08) {
		mode |= CS_MODE_SHFPU;
	}
	if (Data[0] & 0x10) {
		mode |= CS_MODE_SHDSP;
	}
	if (Data[0] & 0x20) {
		mode |= CS_MODE_BIG_ENDIAN;
	}

	csh handle;
	if (cs_open(CS_ARCH_SH, (cs_mode)mode, &handle) != CS_ERR_OK) {
		return 0;
	}
	cs_option(handle, CS_OPT_DETAIL, CS_OPT_ON);

	cs_insn *insn = cs_malloc(handle);
	const uint8_t *code = Data + 1;
	size_t remaining = Size - 1;
	uint64_t address = 0x1000;

	while (cs_disasm_iter(handle, &code, &remaining, &address, insn)) {
		// Touch the strings and detail the way a client would.
		volatile char c = insn->mnemonic[0] + insn->op_str[0];
		(void)c;
		if (insn->detail) {
			volatile uint8_t n = insn->detail->sh.op_count;
			(void)n;
		}
	}

	cs_free(insn, 1);
	cs_close(&handle);
	return 0;
}
