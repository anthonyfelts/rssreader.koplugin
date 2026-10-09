-- Checks the Feedbin backend against the real API. Opt-in only:
--
--   FEEDBIN_LIVE=1 FEEDBIN_EMAIL=you@example.com FEEDBIN_PASSWORD=... spec/run.sh live
--
-- Everything is read-only except one story, which is marked read/unread and
-- starred/unstarred and then put back exactly as it was.
local T = dofile(os.getenv("RSSREADER_REPO") .. "/spec/helper.lua")

if os.getenv("FEEDBIN_LIVE") ~= "1" then
    T.skip_file("live Feedbin specs (set FEEDBIN_LIVE=1, FEEDBIN_EMAIL and FEEDBIN_PASSWORD)")
end
local email, password = os.getenv("FEEDBIN_EMAIL"), os.getenv("FEEDBIN_PASSWORD")
if not email or email == "" or not password or password == "" then
    T.skip_file("FEEDBIN_LIVE=1 needs FEEDBIN_EMAIL and FEEDBIN_PASSWORD")
end

local Feedbin = require("rssreader_feedbin")
local FeedbinSanitizer = require("sanitizers/rssreader_sanitizer_feedbin")

local client = Feedbin:new({ name = "Live Feedbin", type = "feedbin", auth = { username = email, password = password } })

local function idSet(ids)
    local set = {}
    for _, id in ipairs(ids or {}) do
        set[tostring(id)] = true
    end
    return set
end

T.describe("live Feedbin", function()
    local tree
    T.it("loads the tree with the virtual feeds and unread counts", function()
        local ok
        ok, tree = client:buildTree(true)
        T.truthy(ok, tree)
        T.eq(tree.children[1].id, Feedbin.ALL_FEEDS_ID)
        T.eq(tree.children[3].id, Feedbin.STARRED_ID)
        local counted = 0
        local function walk(node)
            for _, child in ipairs(node.children or {}) do
                if child.kind == "folder" then
                    walk(child)
                elseif not child._virtual then
                    T.eq(type(child.feed.unreadCount), "number")
                    counted = counted + child.feed.unreadCount
                end
            end
        end
        walk(tree)
        local _, unread = client:fetchUnreadIds()
        T.truthy(counted <= #unread * 3, "counts cannot exceed unread (times multi-tag folders)")
    end)

    local unread_page
    T.it("loads All Unread with only unread stories, read flags from the ID list", function()
        local ok
        ok, unread_page = client:fetchStories(Feedbin.ALL_UNREAD_ID, { page = 1 })
        T.truthy(ok, unread_page)
        for _, story in ipairs(unread_page.stories) do
            T.eq(story.read, false, "story " .. story.id)
            T.truthy(story.feed_title, "feed title for the prefix")
        end
    end)

    T.it("loads Starred with only starred stories", function()
        local ok, page = client:fetchStories(Feedbin.STARRED_ID, { page = 1 })
        T.truthy(ok, page)
        for _, story in ipairs(page.stories) do
            T.eq(story.starred, true, "story " .. story.id)
        end
    end)

    T.it("answers a page past the end of a feed with no stories", function()
        local feed_id = unread_page and unread_page.stories[1] and unread_page.stories[1].feed_id
        if not feed_id then
            return
        end
        local ok, page = client:fetchStories(feed_id, { page = 9999 })
        T.truthy(ok, page)
        T.eq(#page.stories, 0)
    end)

    T.it("extracts a story's full article", function()
        local ok, page = client:fetchStories(Feedbin.ALL_FEEDS_ID, { page = 1 })
        T.truthy(ok, page)
        local url = FeedbinSanitizer.extractionUrl(page.stories[1])
        T.truthy(url, "extraction link on the story")
        local html
        FeedbinSanitizer.fetchArticle(url, function(payload)
            html = FeedbinSanitizer.parseResponse(payload)
        end)
        T.truthy(html and #html > 0, "extracted HTML")
    end)

    T.it("marks one story read/unread and starred/unstarred, then restores it", function()
        local ok, page = client:fetchStories(Feedbin.ALL_FEEDS_ID, { page = 1 })
        T.truthy(ok, page)
        local story = page.stories[1]
        local _, unread_before = client:fetchUnreadIds()
        local _, starred_before = client:fetchStarredIds()
        local was_unread = idSet(unread_before)[story.id] or false
        local was_starred = idSet(starred_before)[story.id] or false

        local function state()
            local _, unread = client:fetchUnreadIds()
            local _, starred = client:fetchStarredIds()
            return idSet(unread)[story.id] or false, idSet(starred)[story.id] or false
        end
        local function restore()
            if was_unread then client:markStoryAsUnread(nil, story) else client:markStoryAsRead(nil, story) end
            if was_starred then client:markStoryAsStarred(nil, story) else client:markStoryAsUnstarred(nil, story) end
        end

        local checks_ok, err = pcall(function()
            client:markStoryAsRead(nil, story)
            T.eq((state()), false, "unread after markStoryAsRead")
            client:markStoryAsUnread(nil, story)
            T.eq((state()), true, "unread after markStoryAsUnread")
            client:markStoryAsStarred(nil, story)
            T.eq(select(2, state()), true, "starred after markStoryAsStarred")
            client:markStoryAsUnstarred(nil, story)
            T.eq(select(2, state()), false, "starred after markStoryAsUnstarred")
        end)
        restore()
        local unread_after, starred_after = state()
        T.eq({ unread_after, starred_after }, { was_unread, was_starred }, "story restored")
        if not checks_ok then
            error(err, 0)
        end
    end)
end)

T.finish()
