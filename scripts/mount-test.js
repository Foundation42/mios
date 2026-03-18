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

    // Send to the console actor by name!
    print("");
    term.color("yellow");
    print("Sending to console actor...");
    term.reset();

    actor.send("console", 0xFF000060, "Hello from MiOS!\n");
    actor.send("console", 0xFF000060, "The GUI shell has mounted to the microkernel.\n");
    actor.send("console", 0xFF000060, "MiOS <-> Microkernel bridge is alive!\n");

    print("");
    term.color("cyan");
    print("Check the mk-shell terminal — you should see the messages!");
    print("Bridge is live. Connected: " + actor.connected());
    term.reset();
}
