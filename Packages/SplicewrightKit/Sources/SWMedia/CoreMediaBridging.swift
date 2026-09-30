import CoreMedia
import SWCore

public extension RationalTime {
    init(_ time: CMTime) {
        if time.isValid, time.isNumeric, time.timescale > 0 {
            self.init(value: time.value, timescale: time.timescale)
        } else {
            self = .zero
        }
    }

    var cmTime: CMTime {
        CMTime(value: value, timescale: timescale)
    }
}

public extension FrameRate {
    var cmFrameDuration: CMTime {
        CMTime(value: CMTimeValue(denominator), timescale: numerator)
    }
}
