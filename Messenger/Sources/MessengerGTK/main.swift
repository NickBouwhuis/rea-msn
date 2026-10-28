import MessengerGTKUI
import MSNKit

// Windows Live Messenger on Escargot (MSNP15), GTK4.
MainActor.assumeIsolated { MessengerGTKLauncher.run(EscargotProfile()) }
