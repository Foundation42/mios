// Mount test — connect to real microkernel and send messages by name
term.color("cyan");
print("=== Microkernel Mount Test ===");
term.reset();

const host = "127.0.0.1";
const port = 4200;

print("Mounting to " + host + ":" + port + "...");
const result = actor.mount(host, port);

if (!result || result === false) {
    term.color("red");
    print("Failed! Is the microkernel running?");
    print("  cd ~/dev/microkernel && ./build/tools/shell/mk-shell");
    term.reset();
} else {
    term.color("green");
    print("Node ID: " + result.nodeId + ", Identity: " + result.identity);
    term.reset();

    // Send MSG_CONSOLE_WRITE to the console actor
    // This writes directly to mk-shell's stdout
    print("");
    term.color("yellow");
    print("Sending to console...");
    term.reset();

    actor.send("console", 0xFF000060, "\n--- Message from MiOS ---\n");
    actor.send("console", 0xFF000060, "Hello from MiOS! The GUI shell is connected.\n");
    actor.send("console", 0xFF000060, "--- End of message ---\n\n");

    print("");
    term.color("cyan");
    print("Check the mk-shell terminal!");
    print("Bridge is live. Connected: " + actor.connected());
    term.reset();
}
