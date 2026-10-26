#!/usr/bin/env python3
from generated import validate_advanced, validate_event, validate_user

pass_ = True


def assert_(condition: bool, message: str) -> None:
    global pass_
    if not condition:
        print(f"FAIL: {message}")
        pass_ = False


assert_(
    len(validate_user({"name": "Alice", "age": 30, "email": "alice@example.com"})) == 0,
    "valid user should have no errors",
)

user_errors = validate_user({"name": "Alice", "age": "thirty", "email": "alice@example.com"})
assert_(len(user_errors) > 0, "invalid user age should produce errors")
assert_(
    any(e["instancePath"] == "/age" for e in user_errors),
    "user age error should reference /age",
)

assert_(
    len(
        validate_event(
            {
                "id": "evt-1",
                "created_at": "2026-01-01T00:00:00Z",
                "status": "active",
                "tags": ["a", "b"],
            }
        )
    )
    == 0,
    "valid event should have no errors",
)

event_errors = validate_event(
    {
        "id": "evt-2",
        "created_at": "2026-01-01T00:00:00Z",
        "status": "deleted",
    }
)
assert_(len(event_errors) > 0, "invalid event status should produce errors")
assert_(
    any(e["instancePath"] == "/status" for e in event_errors),
    "event status error should reference /status",
)

assert_(
    len(
        validate_advanced(
            {
                "profile": {"author": {"name": "Alice", "bio": None}},
                "errors": {"email": ["must be valid"], "name": []},
            }
        )
    )
    == 0,
    "nullable field, values map, and nested references should validate",
)

advanced_errors = validate_advanced(
    {
        "profile": {"author": {"name": "Alice", "bio": 42}},
        "errors": {"email": "must be a list"},
    }
)
assert_(
    any(e["instancePath"] == "/profile/author/bio" for e in advanced_errors),
    "invalid nullable field should reference nested ref path",
)
assert_(
    any(e["instancePath"] == "/errors/email" for e in advanced_errors),
    "invalid values map entry should reference map key path",
)

if pass_:
    print("Python validator fixture test PASSED")
    raise SystemExit(0)

print("Python validator fixture test FAILED")
raise SystemExit(1)
