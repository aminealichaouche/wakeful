/// Which build this is. The offline edition is compiled with `-DOFFLINE` (see scripts/build-app.sh)
/// and contains no update checker or any other network code.
enum Edition {
    #if OFFLINE
    static let isOffline = true
    static let aboutText = "An open-source app that keeps your Mac awake.\nOffline edition: never connects to the internet."
    #else
    static let isOffline = false
    static let aboutText = "An open-source app that keeps your Mac awake."
    #endif
}
