import Foundation
import PlumbReplay

// Reads the command line, replays, prints. Everything it does is in PlumbReplay, where it is tested.

let request: ReplayRequest
do {
    request = try ReplayOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}

switch request {
case .help:
    print(ReplayOptions.usage)
case .replay(let options):
    do {
        print(try ReplayCommand.run(options), terminator: "")
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
