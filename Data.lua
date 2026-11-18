-- CommodityTicker: default watch lists (commodities only). Item IDs checked against the
-- Americas Normal Horde auction house and Wowhead/GameMaps Forever item pages (11 Nov 2026; charms 12 Nov 2026; ores and Arcane Crystal 14 Nov 2026).
local _, ns = ...

ns.LISTS = {
  -- Level ~38 farming and Alchemy 225-250 (plus Philosopher's Stone mats).
  now = {
    { id = 4611,   name = "Blue Pearl" },
    { id = 3369,   name = "Grave Moss" },
    { id = 3819,   name = "Wintersbite" },
    { id = 4625,   name = "Firebloom" },
    { id = 3821,   name = "Goldthorn" },
    { id = 3357,   name = "Liferoot" },
    { id = 8831,   name = "Purple Lotus" },
    { id = 3818,   name = "Fadeleaf" },
    { id = 3358,   name = "Khadgar's Whisker" },
    { id = 8153,   name = "Wildvine" },
    { id = 3356,   name = "Kingsblood" },
    { id = 249399, name = "Frilled Lichen" },  -- Forever bonus material from mid-level herb nodes
    { id = 249424, name = "Rosecap" },         -- Forever bonus material
    { id = 3575,   name = "Iron Bar" },        -- Philosopher's Stone mat
    { id = 9262,   name = "Black Vitriol" },   -- Philosopher's Stone mat
    -- Warrior Whirlwind/Cyclonian charms (quests 1714 Essence of the Exile, 1712 Cyclonian).
    -- Tradeable common consumables, stack of 10, no bind, not quest items; listed on the AH.
    -- The Americas Normal Horde auction house lists them (item class Consumable; the feed includes
    -- them because they are on this watch list). Wowhead Forever item=4479 / 4480 / 4481.
    -- Not listed: Essence of the Exile (6851) is a quest item.
    { id = 4479,   name = "Burning Charm" },
    { id = 4480,   name = "Thundering Charm" },
    { id = 4481,   name = "Cresting Charm" },
    -- Mining ores, Arcane Crystal, and Arcanite Bar (14 Nov 2026). All tradeable
    -- Metal & Stone / Other crafting reagents, stack of 20, no bind, listed on the AH.
    -- Small and Rich Thorium veins both drop Thorium Ore (10620); added once.
    -- Wowhead Forever: item=2770, 2771, 2775, 2772, 2776, 3858, 7911, 10620, 12363, 12360.
    -- Dark Iron Ore (11370) confirmed on the Americas Normal Horde AH / questing.wiki / 60.tools.
    { id = 2770,   name = "Copper Ore" },
    { id = 2771,   name = "Tin Ore" },
    { id = 2775,   name = "Silver Ore" },
    { id = 2772,   name = "Iron Ore" },
    { id = 2776,   name = "Gold Ore" },
    { id = 3858,   name = "Mithril Ore" },
    { id = 7911,   name = "Truesilver Ore" },
    { id = 10620,  name = "Thorium Ore" },
    { id = 11370,  name = "Dark Iron Ore" },
    { id = 12363,  name = "Arcane Crystal" },
    { id = 12360,  name = "Arcanite Bar" },
  },
  -- Level ~50+ high-value watch list.
  later = {
    { id = 13468,  name = "Black Lotus" },
    { id = 249274, name = "Stranglevine" },
    { id = 13467,  name = "Icecap" },
    { id = 13466,  name = "Plaguebloom" },
    { id = 13465,  name = "Mountain Silversage" },
    { id = 8845,   name = "Ghost Mushroom" },
    { id = 13463,  name = "Dreamfoil" },
    { id = 8846,   name = "Gromsblood" },
    { id = 13464,  name = "Golden Sansam" },
    { id = 248822, name = "Death Lotus" },     -- new in Forever, not listed yet on 11 Nov
    { id = 248821, name = "Demonsage" },       -- new in Forever, not listed yet on 11 Nov
    { id = 248823, name = "Marefoil" },        -- new in Forever, not listed yet on 11 Nov
  },
}
