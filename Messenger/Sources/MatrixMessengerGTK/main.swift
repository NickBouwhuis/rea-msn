import MatrixKit
import MessengerGTKUI

// Messenger for Matrix, GTK4 (the plain client-server client until
// matrix-rust-sdk is built for Linux).
MainActor.assumeIsolated { MessengerGTKLauncher.run(MatrixProfile()) }
