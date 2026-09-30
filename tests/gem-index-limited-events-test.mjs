import assert from "node:assert/strict";
import test from "node:test";
import {
  gemEventSourceLabel,
  isLimitedEventGem,
  limitedEventName
} from "../src/logic/gemIndex.js";

test("time-bounded event gems are classified as Limited without including random events", () => {
  assert.equal(isLimitedEventGem({ availabilityMode: "date_range" }), true);
  assert.equal(isLimitedEventGem({ availabilityMode: "date_range_daily" }), true);
  assert.equal(isLimitedEventGem({ availabilityMode: "always", metadata: { limited: true } }), true);
  assert.equal(isLimitedEventGem({ availabilityMode: "global_event" }), false);
  assert.equal(isLimitedEventGem({ availabilityMode: "daily" }), false);
});

test("limited gem source labels use their associated event", () => {
  assert.equal(
    gemEventSourceLabel({ name: "Twentiethite", availabilityMode: "date_range" }),
    "Obtained from Gem Incremental's Twentieth Day"
  );
  assert.equal(
    gemEventSourceLabel({ name: "Monthstone", availabilityMode: "date_range" }),
    "Obtained from the Month One anniversary"
  );
  assert.equal(
    limitedEventName({ availabilityMode: "date_range", metadata: { deepcore_stage: 4 } }),
    "the Deepcore Project 2026"
  );
  assert.equal(
    gemEventSourceLabel({
      name: "Duolite",
      availabilityMode: "date_range",
      metadata: { anniversary: "month-2", limited: true }
    }),
    "Obtained from the Month Two anniversary"
  );
});

test("permanent random-event gems identify the random event", () => {
  assert.equal(
    gemEventSourceLabel({ availabilityMode: "global_event", requiredEventKey: "meteor_shower" }),
    "Obtained during Meteor Shower"
  );
  assert.equal(
    gemEventSourceLabel({ availabilityMode: "always", requiredEventKey: "abyssal_potion" }),
    ""
  );
});

test("the Gem Index places Limited between Secret and Anomalous", async () => {
  const source = await import("node:fs/promises").then(({ readFile }) =>
    readFile(new URL("../gem-index/index.js", import.meta.url), "utf8")
  );
  assert.match(source, /"secret", "limited", "anomalous"/);
  assert.match(source, /isLimitedEventGem\(entry\.gem\) \? LIMITED_TIER : baseTier\(entry\)/);
});
