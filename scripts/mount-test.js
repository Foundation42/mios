// Mount a remote microkernel node — a terminal window will appear
term.color("cyan");
print("=== Mount Remote Node ===");
term.reset();

const host = __args || "127.0.0.1";
const port = 4200;

print("Mounting " + host + ":" + port + "...");
actor.mount(host, port);
print("Mount request sent — terminal will appear when connected.");
print("From mk-shell, try: send mios-console 4278190176 Hello MiOS!");
