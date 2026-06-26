.PHONY: build geas checksums test clean

build: geas
	mkdir -p bytecode

	# 2935
	mkdir -p bytecode/execution_hash
	bin/geas -a -no-nl -o bytecode/execution_hash/main.hex src/execution_hash/main.eas
	bin/geas -a -no-nl -o bytecode/execution_hash/ctor.hex src/execution_hash/ctor.eas

	# 4788
	mkdir -p bytecode/beacon_root
	bin/geas -a -no-nl -o bytecode/beacon_root/main.hex src/beacon_root/main.eas
	bin/geas -a -no-nl -o bytecode/beacon_root/ctor.hex src/beacon_root/ctor.eas

	# 7002
	mkdir -p bytecode/withdrawals
	bin/geas -a -no-nl -o bytecode/withdrawals/main.hex src/withdrawals/main.eas
	bin/geas -a -no-nl -o bytecode/withdrawals/ctor.hex src/withdrawals/ctor.eas

	# 7251
	mkdir -p bytecode/consolidations
	bin/geas -a -no-nl -o bytecode/consolidations/main.hex src/consolidations/main.eas
	bin/geas -a -no-nl -o bytecode/consolidations/ctor.hex src/consolidations/ctor.eas

	# test helper
	mkdir -p bytecode/fake_expo_test
	bin/geas -a -no-nl -o bytecode/fake_expo_test/main.hex src/common/fake_expo_test.eas

geas:
	mkdir -p bin
	env "GOBIN=$(PWD)/bin" go install github.com/fjl/geas/cmd/geas@v0.3.2

checksums:
	shasum -a 256 -c checksums.txt

test:
	forge test

clean:
	rm -f bin/geas
	rm -fr bytecode
