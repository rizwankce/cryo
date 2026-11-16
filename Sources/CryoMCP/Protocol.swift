import CryoAPI

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

extension JSONValue {
	var stringValue: String? {
		if case .string(let s) = self { return s }
		return nil
	}

	var numberValue: Double? {
		if case .number(let n) = self { return n }
		return nil
	}

	var boolValue: Bool? {
		if case .bool(let b) = self { return b }
		return nil
	}

	var objectValue: [String: JSONValue]? {
		if case .object(let o) = self { return o }
		return nil
	}

	/// Any Encodable (wire types) as a JSON value.
	static func encoding<T: Encodable>(_ value: T) -> JSONValue {
		guard let data = try? CryoJSON.encoder().encode(value),
			let v = try? CryoJSON.decoder().decode(JSONValue.self, from: data)
		else { return .null }
		return v
	}

	/// One compact line of JSON (no raw newlines: they are escaped inside strings).
	func line() -> String {
		let data = (try? CryoJSON.encoder().encode(self)) ?? Data("null".utf8)
		return String(decoding: data, as: UTF8.self)
	}
}

enum RPCCode {
	static let parseError = -32700
	static let invalidRequest = -32600
	static let methodNotFound = -32601
	static let invalidParams = -32602
}

func rpcResult(id: JSONValue, _ result: JSONValue) -> JSONValue {
	.object(["jsonrpc": .string("2.0"), "id": id, "result": result])
}

func rpcError(id: JSONValue, code: Int, _ message: String) -> JSONValue {
	.object([
		"jsonrpc": .string("2.0"), "id": id,
		"error": .object(["code": .number(Double(code)), "message": .string(message)]),
	])
}

/// What a tool returns: text for the model, structured data for programs.
struct ToolOutput {
	var text: String
	var structured: [String: JSONValue] = [:]
	var isError = false

	static func failure(_ text: String) -> ToolOutput { ToolOutput(text: text, structured: [:], isError: true) }

	var json: JSONValue {
		var o: [String: JSONValue] = [
			"content": .array([.object(["type": .string("text"), "text": .string(text)])]),
			"isError": .bool(isError),
		]
		if !structured.isEmpty { o["structuredContent"] = .object(structured) }
		return .object(o)
	}
}

// MARK: tool definitions

private func prop(_ type: String, _ description: String) -> JSONValue {
	.object(["type": .string(type), "description": .string(description)])
}

private func tool(_ name: String, _ description: String, _ props: [String: JSONValue], required: [String] = []) -> JSONValue {
	.object([
		"name": .string(name),
		"description": .string(description),
		"inputSchema": .object([
			"type": .string("object"),
			"properties": .object(props),
			"required": .array(required.map { .string($0) }),
		]),
	])
}

let leaseFolderPath = "/Volumes/My Shared Files"

let toolDefinitions: [JSONValue] = [
	tool(
		"lease_mac",
		"Lease a clean, isolated macOS VM (a capsule) from the team's bay. Returns the lease id to pass to the other tools. "
			+ "The lease is kept alive while this server runs; it expires about 5 minutes after the server dies. "
			+ "When every capsule is busy it waits up to \(MCPServer.defaultLeaseWaitS) s and then fails; call it again to keep waiting. "
			+ "Work in \(leaseFolderPath). Release it with release_mac when done.",
		[
			"folder": prop("string", "Folder on the bay's Mac to clone into the capsule; it appears at \(leaseFolderPath)."),
			"cache": prop("string", "Named cache to mount (for example derived data or package caches)."),
			"name": prop("string", "Label for the lease, shown in `cryo ls`."),
		]),
	tool(
		"run",
		"Run a shell command in the leased macOS VM over SSH and return its exit code, stdout and stderr "
			+ "(each capped at about 100 KB, the tail is kept). Work in \(leaseFolderPath).",
		[
			"lease": prop("string", "Lease id from lease_mac, for example L81."),
			"command": prop("string", "Shell command to run on the VM."),
			"timeout": prop("number", "Seconds before the command is killed (default 600, max 3600)."),
		],
		required: ["lease", "command"]),
	tool(
		"copy_in",
		"Copy a local file or folder (recursively) into the leased VM. The lease's folder is \(leaseFolderPath); "
			+ "a relative remote path is relative to the VM user's home directory.",
		[
			"lease": prop("string", "Lease id from lease_mac."),
			"local": prop("string", "Path on this machine."),
			"remote": prop("string", "Destination path on the VM, for example \"\(leaseFolderPath)/out\"."),
		],
		required: ["lease", "local", "remote"]),
	tool(
		"copy_out",
		"Copy a file or folder (recursively) from the leased VM to this machine. The lease's folder is \(leaseFolderPath); "
			+ "a relative remote path is relative to the VM user's home directory.",
		[
			"lease": prop("string", "Lease id from lease_mac."),
			"remote": prop("string", "Path on the VM, for example \"\(leaseFolderPath)/build.log\"."),
			"local": prop("string", "Destination path on this machine."),
		],
		required: ["lease", "remote", "local"]),
	tool(
		"release_mac",
		"Release a lease: the VM is stopped and discarded. Copy out anything you need first.",
		[
			"lease": prop("string", "Lease id from lease_mac."),
			"save_cache": prop("boolean", "Keep this lease's cache for the next lease that asks for it."),
		],
		required: ["lease"]),
	tool("status", "Show the bay: its capsules, which leases hold them, and how many requests wait.", [:]),
]

/// The short version of the agent skill (skills/cryo/SKILL.md), sent in `initialize`.
let serverInstructions = """
	Cryo gives you clean macOS VMs for building and testing Apple-platform code. \
	Call lease_mac, then run / copy_in / copy_out, then release_mac. \
	Work in \(leaseFolderPath). \
	Reuse one booted Simulator and pass -parallel-testing-enabled NO to xcodebuild. \
	Never leave work only in the VM: copy results out or push before release_mac. \
	Release the lease when done.
	"""
