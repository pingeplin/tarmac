/// The last result of a costly piece of work, kept so that asking again with
/// the same input does not repeat it. `forget` is for when something the work
/// reads besides its input has changed.
public struct LastResult<Input: Equatable, Output> {
    private var last: (input: Input, output: Output)?

    public init() {}

    public mutating func value(for input: Input, _ work: (Input) -> Output) -> Output {
        if let last, last.input == input { return last.output }
        let output = work(input)
        last = (input, output)
        return output
    }

    public mutating func forget() {
        last = nil
    }
}
