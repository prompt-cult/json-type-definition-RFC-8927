import {
  validateUser,
  validateEvent,
  validateOrderItem,
  validateSharedUserData,
} from "./generated/validators.mjs";

let pass = true;

function assert(condition, message) {
  if (!condition) {
    console.error(`FAIL: ${message}`);
    pass = false;
  }
}

// Valid user
assert(
  validateUser({ name: "Alice", age: 30, email: "alice@example.com" }).length === 0,
  "valid user should have no errors",
);

// Invalid user: wrong type for age
const userErrors = validateUser({ name: "Alice", age: "thirty", email: "alice@example.com" });
assert(userErrors.length > 0, "invalid user age should produce errors");
assert(
  userErrors.some((e) => e.instancePath === "/age"),
  "user age error should reference /age",
);

// Valid event
assert(
  validateEvent({
    id: "evt-1",
    created_at: "2026-01-01T00:00:00Z",
    status: "active",
    tags: ["a", "b"],
  }).length === 0,
  "valid event should have no errors",
);

// Invalid event: bad enum
const eventErrors = validateEvent({
  id: "evt-2",
  created_at: "2026-01-01T00:00:00Z",
  status: "deleted",
});
assert(eventErrors.length > 0, "invalid event status should produce errors");
assert(
  eventErrors.some((e) => e.instancePath === "/status"),
  "event status error should reference /status",
);

// Valid hyphenated-schema barrel export
assert(
  validateOrderItem({ sku: "SKU-1", quantity: 2 }).length === 0,
  "valid order item should have no errors",
);

// Invalid hyphenated-schema barrel export
const orderItemErrors = validateOrderItem({ sku: "SKU-1", quantity: -1 });
assert(orderItemErrors.length > 0, "invalid order item quantity should produce errors");

// Valid nullable value, map, and definition reference
assert(
  validateSharedUserData({
    owner: { id: "usr-1" },
    nickname: null,
    labels: { team: "platform" },
    tags: ["maintainer"],
  }).length === 0,
  "valid shared user data should have no errors",
);

// Invalid map value through the differentiated barrel export
const sharedUserDataErrors = validateSharedUserData({
  owner: { id: "usr-1" },
  nickname: null,
  labels: { team: 1 },
});
assert(
  sharedUserDataErrors.some((e) => e.instancePath === "/labels/team"),
  "invalid shared user data map value should reference /labels/team",
);

if (pass) {
  console.log("MJS validator fixture test PASSED");
  process.exit(0);
} else {
  console.error("MJS validator fixture test FAILED");
  process.exit(1);
}
