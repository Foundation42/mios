// Bridge test — connect to microkernel mock and exchange messages
term.color("cyan");
print("=== Microkernel Bridge Test ===");
term.reset();

// Connect
print("Connecting to /tmp/mios-test.sock...");
const ok = actor.connect("/tmp/mios-test.sock");
if (!ok) {
    term.color("red");
    print("Failed to connect! Is test_server.py running?");
    term.reset();
} else {
    // Check for welcome message
    sleep(100);
    const welcome = actor.recv();
    if (welcome) {
        term.color("green");
        print("Received: type=0x" + welcome.type.toString(16) + " payload=\"" + welcome.payload + "\"");
        term.reset();
    }

    // Send a message
    print("");
    term.color("yellow");
    print("Sending: Hello from MiOS!");
    term.reset();
    actor.send(1, 0xFF000060, "Hello from MiOS!");

    // Wait for echo
    sleep(100);
    const echo = actor.recv();
    if (echo) {
        term.color("green");
        print("Received: type=0x" + echo.type.toString(16) + " payload=\"" + echo.payload + "\"");
        term.reset();
    } else {
        term.color("red");
        print("No response received");
        term.reset();
    }

    // Send another
    print("");
    term.color("yellow");
    print("Sending: MiOS <-> Microkernel bridge is alive!");
    term.reset();
    actor.send(1, 0xFF000060, "MiOS <-> Microkernel bridge is alive!");

    sleep(100);
    const echo2 = actor.recv();
    if (echo2) {
        term.color("green");
        print("Received: type=0x" + echo2.type.toString(16) + " payload=\"" + echo2.payload + "\"");
        term.reset();
    }

    print("");
    term.color("cyan");
    print("Bridge test complete! Connected: " + actor.connected());
    term.reset();

    actor.close();
}
