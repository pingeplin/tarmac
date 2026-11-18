/// When the app may send a `spawn_term` for a board: connected, its view laid
/// out (a spawn carries the card's grid), and the board built and restored on
/// this connection — that restore lists the live terminals, and a shell
/// spawned ahead of it would be taken for lost.
public enum SpawnReadiness {
    public static func ready(connected: Bool, viewReady: Bool, built: Bool, restored: Bool) -> Bool {
        connected && viewReady && built && restored
    }
}
