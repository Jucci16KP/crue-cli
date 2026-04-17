"""Word lists for generating crue session names.

Picked for:
- 2 syllables max (typeable)
- Unambiguous in speech
- Evocative, not generic
- No vowel-heavy collisions (adj-noun stays readable)
"""
import random

ADJECTIVES = [
    "eager", "silent", "brisk", "keen", "quiet", "swift",
    "bold", "calm", "clever", "crisp", "daring", "dusky",
    "gentle", "glad", "hardy", "jolly", "lively", "merry",
    "nimble", "plain", "proud", "quick", "royal", "rugged",
    "sleek", "sly", "snug", "sober", "spry", "stark",
    "stout", "sturdy", "sunny", "tame", "tidy", "tough",
    "trim", "witty", "wild", "wise", "wiry", "zany",
    "amber", "ashen", "copper", "frosty", "golden", "hazy",
    "misty", "olive", "plum", "rusty", "sable", "tawny",
    "velvet", "ivory", "cobalt", "coral", "pearl", "jade",
]

NOUNS = [
    "cocoa", "harbor", "lantern", "meadow", "falcon", "otter",
    "anchor", "arbor", "beacon", "brook", "canyon", "cedar",
    "cliff", "cobble", "comet", "cove", "crest", "crow",
    "dune", "ember", "fern", "finch", "fjord", "flint",
    "forge", "glen", "gopher", "grove", "harvest", "hazel",
    "heron", "iris", "jasper", "kettle", "koi", "lark",
    "ledge", "linnet", "marble", "marsh", "mesa", "moss",
    "orchard", "pebble", "pine", "plover", "quartz", "raven",
    "reef", "ridge", "river", "saddle", "sage", "sparrow",
    "summit", "thistle", "thorn", "thrush", "tinder", "vale",
]


def pick() -> str:
    """Return a fresh `adj-noun` string. Caller prepends `ju/`."""
    return f"{random.choice(ADJECTIVES)}-{random.choice(NOUNS)}"


if __name__ == "__main__":
    print(pick())
