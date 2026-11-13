/// The words the checker treats as numbers.
enum NumberWords {
    /// Spelled-out numbers that are checked exactly like the same number in digits.
    static let values: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "twice": 2, "thrice": 3,
    ]

    /// Number words the checker cannot turn into one value. A sentence using them is refused,
    /// because otherwise "twenty pauses" would pass as a sentence with no numbers in it.
    static let unreadable: Set<String> = [
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "hundreds", "thousand", "thousands", "million", "millions", "billion", "billions",
        "dozen", "dozens", "couple", "half", "halves", "halved", "quarter", "quarters", "thirds",
        "double", "doubled", "triple", "tripled",
        "ii", "iii", "iv", "vi", "vii", "viii", "ix", "xi", "xii", "xiii", "xiv", "xv", "xx",
    ]

    /// Words that state a count only when the thing counted follows: "no pauses" is zero pauses
    /// and "both pauses" is two. On their own ("no depth was recorded") they are ordinary words.
    static let nounBound: [String: Double] = ["no": 0, "single": 1, "both": 2]

    /// The mark between the two halves of a written fraction such as 3/4.
    static let fractionSlash: Character = "/"
}
