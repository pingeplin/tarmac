import TarmacKit

/// One run of each mark, for the tables of expected runs.
func p(_ text: String) -> InlineRun { InlineRun(text, .plain) }
func b(_ text: String) -> InlineRun { InlineRun(text, .bold) }
func i(_ text: String) -> InlineRun { InlineRun(text, .italic) }
func c(_ text: String) -> InlineRun { InlineRun(text, .code) }
func l(_ text: String) -> InlineRun { InlineRun(text, .link) }
func dot(_ text: String = "•") -> InlineRun { InlineRun(text, .bullet) }
