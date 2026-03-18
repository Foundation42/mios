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

    // Send a shell command to the microkernel!
    // MSG_SHELL_INPUT (100) goes to the "shell" WASM actor
    // It's like typing into the mk-shell terminal
    print("");
    term.color("yellow");
    print("Sending shell command: echo Hello from MiOS!");
    term.reset();

    actor.send("shell", 100, "echo Hello from MiOS!");

    // Wait and check for any response
    sleep(500);
    let msg = actor.recv();
    let count = 0;
    while (msg) {
        term.color("green");
        print("Recv: type=0x" + msg.type.toString(16) + " payload=\"" + msg.payload + "\"");
        term.reset();
        count++;
        msg = actor.recv();
    }

    print("");
    term.color("cyan");
    print("Check mk-shell terminal for output!");
    print("Bridge is live. Connected: " + actor.connected());
    term.reset();
}
