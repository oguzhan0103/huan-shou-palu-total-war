return {
    schemaVersion = "pwft.content-actions.pack.v1",
    contentPackId = "example.minimal.foundation",
    contentVersion = "1.0.0",
    actions = {
        {
            actionId = "example.minimal.action.task-award",
            kind = "award_task_reputation",
            parameters = {
                factionId = "pwft.faction.rayne_syndicate",
                amount = 10,
            },
            requiresPlayerConfirmation = false,
        },
        {
            actionId = "example.minimal.action.claim-keystone",
            kind = "transfer_unique_pal",
            parameters = {
                uniquePalId = "example.minimal.unique.keystone",
                expectedOwner = { kind = "wild" },
                newOwner = { kind = "player" },
            },
            requiresPlayerConfirmation = true,
        },
        {
            actionId = "example.minimal.action.preserve-flag",
            kind = "set_ending_flag",
            parameters = {
                key = "example.minimal.flag.route.preserve",
                value = true,
            },
            requiresPlayerConfirmation = false,
        },
        {
            actionId = "example.minimal.action.preserve-ending",
            kind = "commit_ending_route",
            parameters = {
                routeId = "example.minimal.ending.route.preserve",
            },
            requiresPlayerConfirmation = true,
        },
    },
}
