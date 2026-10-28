import MessengerUI
import MSNKit

// Windows Live Messenger on Escargot (MSNP15).
MainActor.assumeIsolated { MessengerLauncher.run(EscargotProfile()) }
