/// What the avatar of the floating panel shows, and until when (#41).
///
/// A pure state machine: given what happened and when, it says which expression to show and when
/// that changes next. Time and chance are given to it — the instants by whoever drives it, the
/// blinks by a seeded generator — so that a test can walk it through any sequence without waiting.
/// Every expression it can produce is an `AvatarExpression`, and it can produce all of them: the
/// sprites an avatar must have are exactly those this machine shows.
public struct AvatarAnimation: Sendable {
  /// Time since an origin chosen by the driver.
  public typealias Instant = Duration

  public enum Mood: Equatable, Sendable {
    /// Nothing to say: neutral, blinking now and then.
    case idle
    /// A request arrived: surprised, for a moment.
    case attention
    /// The bubble's text is being "read out": the mouth moves.
    case speaking
    /// An answer is being typed into its session.
    case thinking
    /// The answer went through.
    case pleased
    /// The answer could not be sent.
    case worried
  }

  public enum Event: Equatable, Sendable {
    /// A request arrived. `speech` is what the bubble shows, when it is open; folded, the avatar
    /// only reacts.
    case requestArrived(speech: String?)
    /// The bubble shows another request, or unfolded on one.
    case bubbleShown(speech: String)
    /// The bubble folded or closed: the avatar stops talking.
    case bubbleClosed
    /// An answer is being typed.
    case answerSending
    /// The answer went through. `next` is what the bubble shows next, if a request still waits.
    case answerSucceeded(next: String?)
    /// The answer could not be sent.
    case answerFailed
    /// Time passed: nothing happened but the clock.
    case tick
  }

  public struct Frame: Equatable, Sendable {
    public let expression: AvatarExpression
    /// When the expression may change without any event. `nil`: it will not.
    public let nextChange: Instant?
  }

  // The timings, named for the tests.
  public static let blinkPhases: [(AvatarExpression, Duration)] = [
    (.eyesHalfClosed, .milliseconds(60)), (.eyesClosed, .milliseconds(90)),
    (.eyesHalfClosed, .milliseconds(60)),
  ]
  public static let blinkInterval: ClosedRange<Duration> = .seconds(3)...(.seconds(7))
  public static let attentionDuration: Duration = .milliseconds(600)
  public static let mouthCycle: [AvatarExpression] = [
    .mouthHalfOpen, .mouthOpen, .mouthRound, .mouthHalfOpen, .neutral,
  ]
  public static let mouthFrameDuration: Duration = .milliseconds(110)
  public static let pleasedDuration: Duration = .milliseconds(1_200)
  public static let worriedDuration: Duration = .seconds(2)
  public static let maximumSpeech: Duration = .milliseconds(2_500)

  /// How long the mouth moves for a text: longer for a longer text, never so long that it gets
  /// in the way. The bubble shows the whole text at once — answering never waits for the mouth.
  public static func speechDuration(of text: String) -> Duration {
    min(.milliseconds(600) + .milliseconds(40) * text.count, maximumSpeech)
  }

  /// Reduce Motion: one still expression per mood, no blink, no moving mouth.
  public var reducesMotion: Bool

  public private(set) var mood: Mood = .idle
  private var moodStart: Instant = .zero
  /// When the mood ends by itself. `nil` for a mood that waits for an event.
  private var moodEnd: Instant?
  /// What to say once the current mood is over: a request arrived, or the next one after an answer.
  private var pendingSpeech: String?
  /// When the next blink starts, in the idle mood.
  private var nextBlink: Instant
  private var random: SplitMix64

  public init(reducesMotion: Bool = false, seed: UInt64 = 0x5EED, at now: Instant = .zero) {
    self.reducesMotion = reducesMotion
    random = SplitMix64(seed: seed)
    moodStart = now
    nextBlink = now
    nextBlink = now + randomBlinkInterval()
  }

  /// What happened at `now`, and what to show from then on.
  public mutating func handle(_ event: Event, at now: Instant) -> Frame {
    advance(to: now)
    switch event {
    case .tick:
      break
    case .requestArrived(let speech):
      // An answer being typed is not interrupted: the arrival will be seen after it.
      guard mood != .thinking else {
        pendingSpeech = speech ?? pendingSpeech
        break
      }
      pendingSpeech = speech
      enter(.attention, at: now, for: Self.attentionDuration)
    case .bubbleShown(let speech):
      switch mood {
      case .thinking:
        break
      case .attention, .pleased, .worried:
        // Said once the reaction is over.
        pendingSpeech = speech
      case .idle, .speaking:
        speak(speech, at: now)
      }
    case .bubbleClosed:
      pendingSpeech = nil
      if mood == .speaking { enterIdle(at: now) }
    case .answerSending:
      pendingSpeech = nil
      enter(.thinking, at: now, for: nil)
    case .answerSucceeded(let next):
      pendingSpeech = next
      enter(.pleased, at: now, for: Self.pleasedDuration)
    case .answerFailed:
      pendingSpeech = nil
      enter(.worried, at: now, for: Self.worriedDuration)
    }
    return frame(at: now)
  }

  /// What to show at `now`, as things stand. Call `handle(.tick, at:)` to move on first.
  public func frame(at now: Instant) -> Frame {
    switch mood {
    case .idle:
      guard !reducesMotion else { return Frame(expression: .neutral, nextChange: nil) }
      var start = nextBlink
      for (expression, duration) in Self.blinkPhases {
        let end = start + duration
        if now >= start, now < end { return Frame(expression: expression, nextChange: end) }
        start = end
      }
      return Frame(expression: .neutral, nextChange: nextBlink)
    case .attention:
      return Frame(expression: .surprised, nextChange: moodEnd)
    case .speaking:
      guard !reducesMotion, let end = moodEnd else {
        return Frame(expression: .neutral, nextChange: moodEnd)
      }
      let elapsed = now - moodStart
      let index = Int(elapsed / Self.mouthFrameDuration)
      let frameEnd = moodStart + Self.mouthFrameDuration * (index + 1)
      return Frame(
        expression: Self.mouthCycle[index % Self.mouthCycle.count],
        nextChange: min(frameEnd, end))
    case .thinking:
      return Frame(expression: .thinking, nextChange: nil)
    case .pleased:
      return Frame(expression: .pleased, nextChange: moodEnd)
    case .worried:
      return Frame(expression: .worried, nextChange: moodEnd)
    }
  }

  // MARK: - Moving on

  /// Ends every mood whose time is up by `now`, in order.
  private mutating func advance(to now: Instant) {
    while let end = moodEnd, end <= now {
      switch mood {
      case .attention, .pleased:
        if let speech = pendingSpeech {
          pendingSpeech = nil
          if mood == .pleased {
            // Another request waits: the avatar calls for it, then reads it.
            pendingSpeech = speech
            enter(.attention, at: end, for: Self.attentionDuration)
          } else {
            speak(speech, at: end)
          }
        } else {
          enterIdle(at: end)
        }
      case .speaking, .worried:
        enterIdle(at: end)
      case .idle, .thinking:
        moodEnd = nil
      }
    }
    guard mood == .idle else { return }
    // Blinks that are over. After a long sleep — the panel hidden — the next one is counted from
    // now, not caught up on.
    let blinkLength = Self.blinkPhases.reduce(Duration.zero) { $0 + $1.1 }
    while nextBlink + blinkLength <= now {
      let following = nextBlink + blinkLength + randomBlinkInterval()
      nextBlink = following > now ? following : now + randomBlinkInterval()
    }
  }

  private mutating func speak(_ speech: String, at now: Instant) {
    enter(.speaking, at: now, for: Self.speechDuration(of: speech))
  }

  private mutating func enterIdle(at now: Instant) {
    enter(.idle, at: now, for: nil)
    nextBlink = now + randomBlinkInterval()
  }

  private mutating func enter(_ mood: Mood, at now: Instant, for duration: Duration?) {
    self.mood = mood
    moodStart = now
    moodEnd = duration.map { now + $0 }
  }

  private mutating func randomBlinkInterval() -> Duration {
    let lower = Self.blinkInterval.lowerBound
    let span = Self.blinkInterval.upperBound - lower
    let milliseconds = Int(span / .milliseconds(1))
    return lower + .milliseconds(Int(random.next() % UInt64(milliseconds + 1)))
  }
}

/// A small generator with a seed, so that the blinks of a test are always the same.
struct SplitMix64: Sendable {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
