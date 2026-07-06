/// Opnift — a pure-Swift Yamaha FM synthesizer core: OPN/OPNA (YM2203 / YM2608) and
/// OPM (YM2151, the X68000 sound chip).
///
/// Built bottom-up and checked against golden renders (ymfm / fmgen). See the local
/// design notes for the phase plan; this is Phase 1, starting from the operator tables.
public enum Opnift {
    /// Library version. Bump alongside SemVer git tags once published.
    public static let version = "0.3.1"
}
