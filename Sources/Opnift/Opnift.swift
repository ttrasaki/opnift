/// Opnift — a pure-Swift OPN/OPNA (Yamaha YM2203 / YM2608) FM synthesizer core.
///
/// Built bottom-up and checked against golden renders (ymfm / fmgen). See the local
/// design notes for the phase plan; this is Phase 1, starting from the operator tables.
public enum Opnift {
    /// Library version. Bump alongside SemVer git tags once published.
    public static let version = "0.2.2"
}
