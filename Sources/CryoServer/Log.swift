import Foundation

#if canImport(os)
	import os
#endif

/// The server's log. On Apple platforms it is the unified log (subsystem `dev.rizwan.cryo.bay`,
/// `cryo logs` reads the bay's `bay.log` instead); elsewhere it writes one line to stderr. Messages
/// are plain strings, logged as public.
public struct ServerLog: Sendable {
	#if canImport(os)
		private let logger: Logger
		public init(subsystem: String = "dev.rizwan.cryo.bay", category: String) {
			logger = Logger(subsystem: subsystem, category: category)
		}
		public func error(_ message: @autoclosure () -> String) {
			let m = message()
			logger.error("\(m, privacy: .public)")
		}
		public func info(_ message: @autoclosure () -> String) {
			let m = message()
			logger.info("\(m, privacy: .public)")
		}
		public func debug(_ message: @autoclosure () -> String) {
			let m = message()
			logger.debug("\(m, privacy: .public)")
		}
	#else
		private let category: String
		public init(subsystem: String = "dev.rizwan.cryo.bay", category: String) {
			self.category = category
		}
		public func error(_ message: @autoclosure () -> String) { write("error", message()) }
		public func info(_ message: @autoclosure () -> String) { write("info", message()) }
		/// Dropped, as the unified log drops debug lines unless asked for.
		public func debug(_ message: @autoclosure () -> String) {}
		private func write(_ level: String, _ message: String) {
			FileHandle.standardError.write(Data("\(category) \(level): \(message)\n".utf8))
		}
	#endif

	public static let server = ServerLog(category: "server")
}
