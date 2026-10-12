#!/usr/bin/env python3
"""Exercise production peek routing with fixture messages. No app, AX, audio, or model use."""
from pathlib import Path
import argparse
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parent.parent)
parser.add_argument('--revision', help='Read production code from this revision instead of the working tree')
args = parser.parse_args()
root = args.repo.resolve()


def source(path):
    if args.revision:
        return subprocess.check_output(['git', 'show', f'{args.revision}:{path}'], cwd=root, text=True)
    return (root / path).read_text()


controller = source('Tilde/Inlet/InletController.swift')
start = controller.index('    private var notificationStates:')
end = controller.index('    /// Long enough to read;', start)
production_methods = controller[start:end]
fixture = r'''import Foundation
import CoreGraphics

struct Message {
    enum From { case you, tilde }
    enum Delivery { case sent, read, failed(String) }
    var id: String
    var from: From
    var streaming = false
    var trouble = false
    var attentionID: String?
    var delivery: Delivery?
}
struct Attention { var id: String }
final class ModelFixture {
    var thread: [Message] = []
    var attention: [Attention] = []
}
final class InletFixture {
    enum Mode: Equatable { case rest, peek(String), open }
    var mode: Mode = .rest
}
final class ControllerFixture {
    let model = ModelFixture()
    let inlet = InletFixture()
    var minimization = InletMinimization()
    var seen: Set<String> = []
    var peekedFor: String?
    var settled: [String] = []
    var isPeek: Bool { if case .peek = inlet.mode { true } else { false } }
    func set(_ mode: InletFixture.Mode) { inlet.mode = mode }
    func linger(for message: Message) -> Duration { .zero }
    func settle(_ id: String, after delay: Duration) { settled.append(id) }
    func changed() { threadChanged() }
    func minimize() {
        minimization.minimize(in: .zero, messages: notificationStates)
        set(.rest)
    }
'''
fixture += production_methods
fixture += r'''
}

struct Failure: Error, CustomStringConvertible { var description: String }
@main struct RetryPeekChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw Failure(description: description) }
    }
    static func run() throws {
        let controller = ControllerFixture()
        let pendingOwner = Message(id: "first-owner", from: .you, delivery: .sent)
        let pendingReply = Message(id: "first-reply", from: .tilde, streaming: true)
        controller.model.thread = [pendingOwner, pendingReply]
        controller.seen = Set(controller.model.thread.map(\.id))
        controller.minimize()
        controller.changed()
        try check(controller.inlet.mode == .rest, "Initial pending reply did not stay minimized")

        // Conductor's undelivered handler marks the owner failed and removes its empty reply.
        let failedOwner = Message(id: pendingOwner.id, from: .you, delivery: .failed("Offline"))
        controller.model.thread = [failedOwner]
        controller.changed()
        try check(controller.inlet.mode == .peek(failedOwner.id), "Failed delivery did not peek while minimized")

        // Receipt's Try again -> AppModel.retry -> Conductor.retry removes the failed owner,
        // then tap appends a new owner and streaming placeholder with new IDs.
        let retriedOwner = Message(id: "retry-owner", from: .you, delivery: .sent)
        var retriedReply = Message(id: "retry-reply", from: .tilde, streaming: true)
        controller.model.thread = [retriedOwner, retriedReply]
        controller.changed()
        try check(controller.inlet.mode == .rest,
            "RED: retry replaced the failed peek with a streaming reply while minimized: \(controller.inlet.mode)")
        controller.changed()
        try check(controller.inlet.mode == .rest, "Repeated streaming update reopened the minimized retry")

        retriedReply.streaming = false
        controller.model.thread = [retriedOwner, retriedReply]
        controller.changed()
        try check(controller.inlet.mode == .peek(retriedReply.id), "Retry completion did not peek")

        // The missing-message fallback is still available when the user chose to watch streaming.
        let watching = ControllerFixture()
        watching.inlet.mode = .peek(failedOwner.id)
        watching.model.thread = [retriedOwner, Message(id: retriedReply.id, from: .tilde, streaming: true)]
        watching.seen = Set(watching.model.thread.map(\.id))
        watching.changed()
        try check(watching.inlet.mode == .peek(retriedReply.id), "Non-minimized retry lost its streaming fallback")
        print("Retry peek checks passed: failed delivery, minimized retry, repeated updates, completion, visible-stream fallback")
    }
    static func main() {
        do { try run() }
        catch { print("Retry peek check failed: \(error)"); exit(1) }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='tilde-retry-peek-', dir='/tmp') as temp:
    temp = Path(temp)
    implementation = temp / 'InletMinimization.swift'
    implementation.write_text(source('Tilde/Inlet/InletMinimization.swift'))
    generated = temp / 'RetryPeekChecks.swift'
    generated.write_text(fixture)
    binary = temp / 'retry-peek-checks'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', '/tmp/tilde-retry-peek-module-cache',
                    '-swift-version', '6', '-default-isolation', 'MainActor', '-strict-concurrency=complete',
                    '-warnings-as-errors', '-parse-as-library', str(implementation), str(generated), '-o', str(binary)],
                   cwd=root, check=True)
    sys.exit(subprocess.run([str(binary)], cwd=root).returncode)
