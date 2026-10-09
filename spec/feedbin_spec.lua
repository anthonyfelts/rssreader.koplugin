local T = dofile(os.getenv("RSSREADER_REPO") .. "/spec/helper.lua")
local FakeFeedbin = require("fake_feedbin")
local Feedbin = require("rssreader_feedbin")

local ACCOUNT = {
    name = "Test Feedbin",
    type = "feedbin",
    auth = { username = FakeFeedbin.EMAIL, password = FakeFeedbin.PASSWORD },
}

-- Three feeds: 1 tagged "Tech", 2 tagged "Tech" and "News", 3 untagged.
local function newServer(opts)
    opts = opts or {}
    local entries = opts.entries
    if not entries then
        entries = {}
        for id = 1, 6 do
            entries[#entries + 1] = FakeFeedbin.entry(id, ((id - 1) % 3) + 1)
        end
    end
    return FakeFeedbin.new({
        subscriptions = {
            { id = 101, feed_id = 1, title = "Zeta Feed" },
            { id = 102, feed_id = 2, title = "Alpha Feed" },
            { id = 103, feed_id = 3, title = "Loose Feed" },
        },
        taggings = {
            { id = 201, feed_id = 1, name = "Tech" },
            { id = 202, feed_id = 2, name = "Tech" },
            { id = 203, feed_id = 2, name = "News" },
        },
        entries = entries,
        unread = opts.unread or { 1, 2, 3, 4 },
        starred = opts.starred or { 2 },
        extractions = opts.extractions,
    }):install()
end

local function client()
    return Feedbin:new(ACCOUNT)
end

local function childTitles(node)
    local titles = {}
    for _, child in ipairs(node.children or {}) do
        titles[#titles + 1] = child.title
    end
    return titles
end

local function findChild(node, title)
    for _, child in ipairs(node.children or {}) do
        if child.title == title then
            return child
        end
    end
end

-- Each test gets its own data folder state: the entry -> feed cache lives on
-- disk and would otherwise carry over between tests.
local function resetCache()
    os.remove(client():entryFeedsPath())
end

T.describe("Feedbin", function()
    T.describe("requests", function()
        T.it("reports a wrong password as a login failure", function()
            local server = newServer()
            local bad = Feedbin:new({ name = "Bad", type = "feedbin", auth = { username = FakeFeedbin.EMAIL, password = "nope" } })
            local ok, err = bad:buildTree(true)
            T.falsy(ok)
            T.contains(err, "login failed")
            server:uninstall()
        end)

        -- A captive portal (hotel or airport Wi-Fi login) answers with its own
        -- HTML page. With LuaJSON this aborted KOReader even under pcall.
        T.it("reports a reply that is not JSON as an error instead of crashing", function()
            resetCache()
            local server = newServer()
            server.raw_responses["/v2/subscriptions.json"] = "<html><body>Please log in to the Wi-Fi</body></html>"
            local ok, err = client():buildTree(true)
            T.falsy(ok)
            T.contains(err, "Unable to parse Feedbin response")
            server.raw_responses["/v2/subscriptions.json"] = nil
            server.raw_responses["/v2/feeds/1/entries.json"] = "not json"
            local ok_stories, stories_err = client():fetchStories("1", { page = 1 })
            T.falsy(ok_stories)
            T.contains(stories_err, "Unable to parse Feedbin response")
            server:uninstall()
        end)

        T.it("refuses to run without credentials", function()
            local ok, err = Feedbin:new({ name = "Empty", type = "feedbin", auth = {} }):buildTree(true)
            T.falsy(ok)
            T.contains(err, "Missing Feedbin email or password")
        end)
    end)

    T.describe("buildTree", function()
        T.it("puts the virtual feeds first, then folders, then untagged feeds", function()
            resetCache()
            local server = newServer()
            local ok, tree = client():buildTree(true)
            T.truthy(ok, tree)
            T.eq(childTitles(tree), { "★ All Feeds", "★ All Unread", "★ Starred", "News", "Tech", "Loose Feed" })
            T.eq(tree.children[1].id, Feedbin.ALL_FEEDS_ID)
            T.eq(tree.children[2].id, Feedbin.ALL_UNREAD_ID)
            T.eq(tree.children[3].id, Feedbin.STARRED_ID)
            server:uninstall()
        end)

        T.it("shows a feed with several tags in each of its folders, sorted by title", function()
            resetCache()
            local server = newServer()
            local _, tree = client():buildTree(true)
            T.eq(childTitles(findChild(tree, "Tech")), { "Alpha Feed", "Zeta Feed" })
            T.eq(childTitles(findChild(tree, "News")), { "Alpha Feed" })
            T.eq(findChild(tree, "Tech").id, "Tech", "folder id is the tag name")
            server:uninstall()
        end)

        T.it("counts unread entries per feed", function()
            resetCache()
            -- Unread 1..4: feeds 1, 2, 3, 1.
            local server = newServer()
            local _, tree = client():buildTree(true)
            T.eq(findChild(findChild(tree, "Tech"), "Zeta Feed").feed.unreadCount, 2)
            T.eq(findChild(findChild(tree, "Tech"), "Alpha Feed").feed.unreadCount, 1)
            T.eq(findChild(tree, "Loose Feed").feed.unreadCount, 1)
            T.falsy(findChild(tree, "Loose Feed").feed.unreadCountPartial)
            server:uninstall()
        end)
    end)

    T.describe("unread count cache", function()
        -- 250 unread entries, all in feed 1.
        local function bigServer()
            local entries, unread = {}, {}
            for id = 1, 250 do
                entries[#entries + 1] = FakeFeedbin.entry(id, 1)
                unread[#unread + 1] = id
            end
            return newServer({ entries = entries, unread = unread, starred = {} })
        end

        local function zetaCount(tree)
            return findChild(findChild(tree, "Tech"), "Zeta Feed").feed
        end

        T.it("looks up at most one page of 100 new entries per tree load", function()
            resetCache()
            local server = bigServer()
            local _, tree = client():buildTree(true)
            local lookups = server:requestsMatching("GET", "/v2/entries.json")
            T.eq(#lookups, 1, "one entries lookup")
            local ids = 0
            for _ in lookups[1].params.ids:gmatch("[^,]+") do
                ids = ids + 1
            end
            T.eq(ids, 100)
            T.truthy(lookups[1].params.ids:match("^250,249,"), "newest IDs first")
            T.eq(zetaCount(tree).unreadCount, 100)
            T.truthy(zetaCount(tree).unreadCountPartial, "partial while entries are unknown")
            server:uninstall()
        end)

        T.it("keeps what it learned on disk, across clients, until the counts are exact", function()
            resetCache()
            local server = bigServer()
            local counts = {}
            for load = 1, 3 do
                local _, tree = client():buildTree(true)
                counts[load] = { zetaCount(tree).unreadCount, zetaCount(tree).unreadCountPartial and true or false }
            end
            T.eq(counts, { { 100, true }, { 200, true }, { 250, false } })
            server:clearRequests()
            client():buildTree(true)
            T.eq(#server:requestsMatching("GET", "/v2/entries.json"), 0, "no lookups once the cache has caught up")
            server:uninstall()
        end)

        T.it("ignores a corrupted cache file and rebuilds the counts", function()
            resetCache()
            local server = newServer()
            local file = assert(io.open(client():entryFeedsPath(), "w"))
            file:write("{ this is not json")
            file:close()
            local ok, tree = client():buildTree(true)
            T.truthy(ok, tree)
            T.eq(zetaCount(tree).unreadCount, 2)
            server:uninstall()
        end)

        T.it("drops entries that are no longer unread", function()
            resetCache()
            local server = newServer()
            client():buildTree(true)
            server.unread = { [1] = true }
            local _, tree = client():buildTree(true)
            T.eq(zetaCount(tree).unreadCount, 1)
            T.eq(findChild(findChild(tree, "Tech"), "Alpha Feed").feed.unreadCount, 0)
            server:uninstall()
        end)

        T.it("learns the feeds of stories it fetches anyway", function()
            resetCache()
            local server = bigServer()
            local c = client()
            c:fetchStories("1", { page = 1 })
            server:clearRequests()
            local _, tree = c:buildTree(true)
            -- 50 from the story page + 100 looked up.
            T.eq(zetaCount(tree).unreadCount, 150)
            server:uninstall()
        end)
    end)

    T.describe("fetchStories", function()
        T.it("loads a feed's stories with read and starred state from the ID lists", function()
            resetCache()
            local server = newServer()
            local ok, data = client():fetchStories("2", { page = 1 })
            T.truthy(ok, data)
            -- Feed 2 holds entries 5 and 2; newest first.
            T.eq(#data.stories, 2)
            T.eq(data.stories[1].id, "5")
            T.eq(data.stories[1].read, true)
            T.eq(data.stories[2].id, "2")
            T.eq(data.stories[2].read, false)
            T.eq(data.stories[2].starred, true)
            T.eq(data.stories[2].permalink, "https://example.com/2")
            T.eq(data.stories[2].author, "Author 2")
            T.eq(data.more_stories, false)
            server:uninstall()
        end)

        T.it("parses published times as UTC", function()
            resetCache()
            local server = newServer()
            local _, data = client():fetchStories("1", { page = 1 })
            -- 2026-10-07T09:51:43Z
            T.eq(data.stories[1].timestamp, 1791366703 * 1000)
            server:uninstall()
        end)

        T.it("keeps the extraction link for the feedbin sanitizer", function()
            resetCache()
            local server = newServer()
            local _, data = client():fetchStories("1", { page = 1 })
            T.eq(data.stories[1].extracted_content_url, FakeFeedbin.EXTRACT_HOST .. "/parser/feedbin/sig4")
            server:uninstall()
        end)

        T.it("copes with entries whose title, author and content are null", function()
            resetCache()
            local server = newServer()
            server.raw_responses["/v2/feeds/1/entries.json"] = [[
                [{"id":1,"feed_id":1,"title":null,"author":null,"content":null,"summary":null,
                  "url":"https://example.com/1","published":"2026-10-07T09:51:43.000000Z"}]
            ]]
            local ok, data = client():fetchStories("1", { page = 1 })
            T.truthy(ok, data)
            T.eq(data.stories[1].title, "")
            T.eq(data.stories[1].content, "")
            T.eq(data.stories[1].author, nil)
            server:uninstall()
        end)

        T.it("pages by 50 and treats a page past the end as empty", function()
            resetCache()
            local entries = {}
            for id = 1, 60 do
                entries[#entries + 1] = FakeFeedbin.entry(id, 1)
            end
            local server = newServer({ entries = entries, unread = {}, starred = {} })
            local _, first = client():fetchStories("1", { page = 1 })
            T.eq(#first.stories, 50)
            T.eq(first.more_stories, true)
            local _, second = client():fetchStories("1", { page = 2 })
            T.eq(#second.stories, 10)
            T.eq(second.more_stories, false)
            local ok, third = client():fetchStories("1", { page = 3 })
            T.truthy(ok, third)
            T.eq(#third.stories, 0)
            server:uninstall()
        end)

        T.it("serves All Unread and Starred with feed titles for the prefix", function()
            resetCache()
            local server = newServer()
            local _, unread = client():fetchStories(Feedbin.ALL_UNREAD_ID, { page = 1 })
            T.eq(#unread.stories, 4)
            for _, story in ipairs(unread.stories) do
                T.eq(story.read, false)
                T.truthy(story._from_virtual_feed)
            end
            T.eq(unread.stories[1].feed_title, "Zeta Feed")
            local _, starred = client():fetchStories(Feedbin.STARRED_ID, { page = 1 })
            T.eq(#starred.stories, 1)
            T.eq(starred.stories[1].id, "2")
            T.eq(starred.stories[1].feed_title, "Alpha Feed")
            server:uninstall()
        end)
    end)

    T.describe("marking", function()
        T.it("marks a story read and unread", function()
            resetCache()
            local server = newServer()
            local c = client()
            T.truthy(c:markStoryAsRead("1", { id = "1" }))
            T.falsy(server.unread[1])
            T.truthy(c:markStoryAsUnread("1", { id = "1" }))
            T.truthy(server.unread[1])
            T.eq(#server:requestsMatching("POST", "/v2/unread_entries/delete.json"), 1, "read uses the POST delete form")
            server:uninstall()
        end)

        T.it("stars and unstars a story", function()
            resetCache()
            local server = newServer()
            local c = client()
            T.truthy(c:markStoryAsStarred("1", { id = "1" }))
            T.truthy(server.starred[1])
            T.truthy(c:markStoryAsUnstarred("1", { id = "1" }))
            T.falsy(server.starred[1])
            server:uninstall()
        end)

        T.it("marks the whole account read in batches of 1000", function()
            resetCache()
            local entries, unread = {}, {}
            for id = 1, 1500 do
                entries[#entries + 1] = FakeFeedbin.entry(id, 1)
                unread[#unread + 1] = id
            end
            local server = newServer({ entries = entries, unread = unread, starred = {} })
            T.truthy(client():markAllAsRead())
            T.eq(#server:requestsMatching("POST", "/v2/unread_entries/delete.json"), 2)
            T.eq(#server:unreadIds(), 0)
            server:uninstall()
        end)

        T.it("marks only the given feed read", function()
            resetCache()
            local server = newServer()
            T.truthy(client():markFeedAsRead("1"))
            T.eq(server:unreadIds(), { 2, 3 })
            server:uninstall()
        end)

        T.it("marks only the feeds in a folder read", function()
            resetCache()
            local server = newServer()
            T.truthy(client():markCategoryAsRead("Tech"))
            T.eq(server:unreadIds(), { 3 }, "the untagged feed's entry stays unread")
            server:uninstall()
        end)

        T.it("marks only unread starred stories read for Starred", function()
            resetCache()
            local server = newServer({ starred = { 2, 5 } })
            T.truthy(client():markStarredAsRead())
            T.eq(server:unreadIds(), { 1, 3, 4 })
            server:uninstall()
        end)
    end)
end)

T.finish()
