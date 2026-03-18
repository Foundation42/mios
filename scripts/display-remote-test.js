// Test remote display — mount and send display commands to ourselves
// This simulates what a remote node would do
term.color("cyan");
print("=== Remote Display Test ===");
term.reset();

print("Mounting 127.0.0.1:4200...");
actor.mount("127.0.0.1", 4200);
sleep(1000);

// The microkernel can now send display commands to mios-display.
// From mk-shell, try:
//   send mios-display 4278190163 <hex payload>
//
// MSG_DISPLAY_CLEAR = 0xFF000053 = 4278190163
// MSG_DISPLAY_FILL  = 0xFF000052 = 4278190162
// MSG_DISPLAY_TEXT  = 0xFF000056 = 4278190166

print("");
term.color("yellow");
print("Mounted! Now in mk-shell, try these commands:");
term.reset();
print("");
print("  Clear:  send mios-display 4278190163");
print("  Fill:   send mios-display 4278190162 x:0A000A006400640000F800");
print("  Text:   send mios-display 4278190166 x:1400140007E0000048656C6C6F");
print("");
term.color("cyan");
print("The fill command draws a red rectangle.");
print("The text command draws 'Hello' in green.");
print("A display window should appear on your desktop!");
term.reset();
