-- Coming back from an opened article with the RSS button, then walking up
-- with Back, driven through the plugin's real menus without a screen.
local T = dofile(os.getenv("RSSREADER_REPO") .. "/spec/helper.lua")
local FakeFeedbin = require("fake_feedbin")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local json = require("common/json")

-- The tests are offline as far as KOReader knows; run network work at once.
NetworkMgr.runWhenOnline = function(_, fn) fn() end

local ACCOUNT = {
    name = "Test Feedbin",
    type = "feedbin",
    auth = { username = FakeFeedbin.EMAIL, password = FakeFeedbin.PASSWORD },
}
T.config.accounts = { ACCOUNT }

local server = FakeFeedbin.new({
    subscriptions = {
        { id = 101, feed_id = 1, title = "Zeta Feed" },
        { id = 103, feed_id = 3, title = "Loose Feed" },
        { id = 104, feed_id = 4, title = "Gone Feed" },
    },
    taggings = { { id = 201, feed_id = 1, name = "Tech" } },
    entries = {
        FakeFeedbin.entry(1, 1), FakeFeedbin.entry(2, 1),
        FakeFeedbin.entry(3, 3), FakeFeedbin.entry(4, 4),
    },
    unread = { 1, 2, 3, 4 },
}):install()

local RSSReader = require("main")

-- A fresh plugin instance, as KOReader creates one per opened article.
local function newPlugin()
    local plugin = RSSReader:new{ ui = { menu = { registerToMainMenu = function() end } } }
    plugin.closed_articles = 0
    plugin.leaveArticleUnderneath = function(this)
        this.closed_articles = this.closed_articles + 1
    end
    return plugin
end

local function currentMenu(plugin)
    local menu = plugin.current_menu_info and plugin.current_menu_info.menu
    if menu and UIManager:isWidgetShown(menu) then
        return menu
    end
end

local function currentTitle(plugin)
    local menu = currentMenu(plugin)
    return menu and (menu.title or (menu.title_bar and menu.title_bar.title)) or "<nothing shown>"
end

-- What the feed list saves when one of its stories is opened as an article.
local function saveReadingState(plugin, feed_id, feed_title)
    local stories = { { id = "1", story_id = "1", title = "Entry 1", read = false } }
    local file = assert(io.open(plugin.state_file, "w"))
    file:write(json.encode({
        current_feed_state = {
            account_name = ACCOUNT.name,
            feed_id = feed_id,
            feed_title = feed_title,
            stories = stories,
            story_keys = {},
            current_page = 1,
            has_more = false,
            menu_page = 1,
        },
        current_feed_state_timestamp = os.time(),
    }))
    file:close()
end

-- Closes whatever the previous test left on screen.
local function closeAll(plugin)
    local menu = currentMenu(plugin)
    if menu then
        plugin.closing_for_navigation = true
        UIManager:close(menu)
        plugin.closing_for_navigation = false
    end
end

-- The RSS button: ReaderReturn.returnToList.
local function pressRssButton(plugin)
    plugin:openAccountList({ force_restore = true })
end

T.describe("RSS button in an article", function()
    T.it("reopens the feed list the article came from", function()
        local plugin = newPlugin()
        saveReadingState(plugin, "1", "Zeta Feed")
        pressRssButton(plugin)
        T.eq(currentTitle(plugin), "Zeta Feed")
        closeAll(plugin)
    end)

    T.it("walks Back up through the feed's folder, the account, then the account list", function()
        local plugin = newPlugin()
        saveReadingState(plugin, "1", "Zeta Feed")
        pressRssButton(plugin)
        local titles = {}
        for _ = 1, 3 do
            plugin:goBack()
            titles[#titles + 1] = currentTitle(plugin)
        end
        T.eq(titles, { "Tech", ACCOUNT.name, "RSS Accounts" })
        T.truthy(currentMenu(plugin)._rss_is_root_menu, "the account list is the root menu")
        T.eq(plugin.closed_articles, 0, "articles closed while walking up")
        closeAll(plugin)
    end)

    T.it("goes straight to the account for a feed outside any folder", function()
        local plugin = newPlugin()
        saveReadingState(plugin, "3", "Loose Feed")
        pressRssButton(plugin)
        plugin:goBack()
        T.eq(currentTitle(plugin), ACCOUNT.name)
        closeAll(plugin)
    end)

    T.it("falls back to the account's top level when the feed is gone from the tree", function()
        local plugin = newPlugin()
        saveReadingState(plugin, "99", "Unsubscribed Feed")
        pressRssButton(plugin)
        T.eq(currentTitle(plugin), "Unsubscribed Feed")
        plugin:goBack()
        T.eq(currentTitle(plugin), ACCOUNT.name)
        closeAll(plugin)
    end)

    T.it("falls back to the account list when the tree cannot be loaded", function()
        local plugin = newPlugin()
        saveReadingState(plugin, "1", "Zeta Feed")
        pressRssButton(plugin)
        server.failing = true
        plugin:goBack()
        server.failing = false
        T.eq(currentTitle(plugin), "RSS Accounts")
        closeAll(plugin)
    end)
end)

T.describe("account list over an article", function()
    T.it("opens the account when tapped, keeping the article open", function()
        local plugin = newPlugin()
        saveReadingState(plugin, "1", "Zeta Feed")
        pressRssButton(plugin)
        for _ = 1, 3 do
            plugin:goBack()
        end
        local list = currentMenu(plugin)
        T.eq(currentTitle(plugin), "RSS Accounts")
        local entry
        for _, item in ipairs(list.item_table) do
            if item.text == ACCOUNT.name then
                entry = item
            end
        end
        -- What KOReader's Menu does on a tap: the callback, then close_callback.
        list:onMenuSelect(entry)
        T.eq(currentTitle(plugin), ACCOUNT.name)
        T.eq(plugin.closed_articles, 0, "articles closed by the tap")
        closeAll(plugin)
    end)

    T.it("still closes the article when the RSS list is closed with X", function()
        local plugin = newPlugin()
        saveReadingState(plugin, "1", "Zeta Feed")
        pressRssButton(plugin)
        local menu = currentMenu(plugin)
        UIManager:close(menu)
        menu.close_callback()
        T.eq(plugin.closed_articles, 1)
    end)
end)

server:uninstall()
T.finish()
