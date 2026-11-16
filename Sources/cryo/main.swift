import CryoCLI

#if canImport(Glibc)
	import Glibc
#elseif canImport(Musl)
	import Musl
#elseif canImport(Darwin)
	import Darwin
#endif

exit(CryoCLI.main(Array(CommandLine.arguments.dropFirst())))
