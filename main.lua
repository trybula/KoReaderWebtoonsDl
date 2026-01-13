local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local KeyValuePage = require("ui/widget/keyvaluepage")
local NetworkMgr = require("ui/network/manager")
local time = require("ui/time")

local socket = require("socket")
local socketutil = require("socketutil")
local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")  

local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")



local ToonDl = WidgetContainer:extend{
    name = "Webtoon",
    is_doc_only = false,
    conn = nil,
    db_dir = DataStorage:getDataDir() .. "/db/",
    serv_url = "",
    home_dir = "",
    api_key = "",
}


function ToonDl:CreateDB()
    ToonDl.conn:exec([[
    CREATE TABLE IF NOT EXISTS Toons(
        Id INTEGER PRIMARY KEY,
        Name TEXT DEFAULT 'NoName',
        Url TEXT DEFAULT '', 
        Start_ep INTEGER DEFAULT 0,
        End_ep INTEGER DEFAULT 10
    );
    ]])
end

function ToonDl:CloseDB()
    ToonDl.conn:close()
end

local function get_script_dir()
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:match("@?(.*[/\\])")
    return dir or "./"
end

function ToonDl:init()
    self.ui.menu:registerToMainMenu(self)
    --print(get_script_dir())
    local file = io.open(get_script_dir().."config.json", "r")
    if file then
        local content = file:read("*all")  
        file:close()
        local json, err = rapidjson.decode(content)  
        if json then  
            ToonDl.serv_url = json.serv_url
            ToonDl.api_key = json.api_key
            ToonDl.home_dir = json.dl_dir
        else
            print("error, while parsing config")
        end
    else
        print("cant open config file")
    end
    if ToonDl.home_dir == "" then --put home_dir if nothing was given
        ToonDl.home_dir = G_reader_settings:readSetting("home_dir") or require("apps/filemanager/filemanagerutil").getDefaultDir()  or "."
    end
    local db_file = ToonDl.db_dir .. 'webtoon_plugin.sqlite3'
    lfs.mkdir(ToonDl.db_dir)
    --os.remove(db_file) -- only for dev

    ToonDl.conn = SQ3.open(db_file)
    ToonDl:CreateDB()
    --self:onDispatcherRegisterActions()
    
end


local url_input
url_input = MultiInputDialog:new{
    db_id = -1,
    title = _("Add webtoon url"),
    fields = {
        {
            description = _("How you want this comic to be called?"),
            -- input_type = nil, -- default for text
            hint = _("BestMangaEver"),
            text=""
        },
        {
            description = _("Full Webtoon url"),
            hint = _("https://www.webtoons.com"),
            text = "https://www.webtoons.com",
        },
        {
            description = _("From which episode start downloading"),
            input_type = "number",
            text = 0,
            hint = 0,
        },
        {
            description = _("on which end"),
            input_type = "number",
            text = 10,
            hint = 10,
        },
    },
    buttons = {
        {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(url_input)
                end
            },
            {
                text = _("Save & Exit"),
                callback = function(touchmenu_instance)
                    local fields = url_input:getFields()
                    -- check for user input
                    if fields[1] ~= "" and fields[2] ~= "" then
                        local stmt = ToonDl.conn:prepare("INSERT INTO Toons (Url,Name,Start_ep,End_ep) VALUES (?,?,?,?);")
                        stmt:reset():bind(fields[2],fields[1],fields[3],fields[4]):step()
                        -- insert code here
                        UIManager:close(url_input)
                        
                        -- If we have a touch menu: Update menu entries,
                        -- when called from a menu
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    else
                        -- not all fields where entered
                        UIManager:show(InfoMessage:new{
                            text = _("Not all fields where entered!!!"),
                        })

                    end
                end
            },
        },
    },
}

function ToonDl:edit_comic_screen(id)
    local name,ende,starte,url = ToonDl.conn:rowexec("SELECT Name,End_ep,Start_ep,Url FROM Toons WHERE Id =".. tostring(id))

    local edit_input
    edit_input = MultiInputDialog:new{
        db_id = -1,
        title = _("Add webtoon url"),
        fields = {
            {
                description = _("How you want this comic to be called?"),
                -- input_type = nil, -- default for text
                hint = _("BestToonEver"),
                text=name
            },
            {
                description = _("Full Webtoon url"),
                hint = _("https://webtoon.com"),
                text = url,
            },
            {
                description = _("From which episode start downloading"),
                input_type = "number",
                text = tonumber(starte),
                hint = 0,
            },
            {
                description = _("on which end"),
                input_type = "number",
                text = tonumber(ende),
                hint = 10,
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(edit_input)
                    end
                },
                {
                    text = _("Save & Exit"),
                    callback = function(touchmenu_instance)
                        local fields = edit_input:getFields()
                        -- check for user input
                        if fields[1] ~= "" and fields[2] ~= "" then
                            local stmt = ToonDl.conn:prepare("UPDATE Toons  SET Url = ?,Name=?,Start_ep=?,End_ep=? WHERE Id ="..tostring(id))
                            stmt:reset():bind(fields[2],fields[1],fields[3],fields[4]):step()
                            -- insert code here
                            UIManager:close(edit_input)
                            
                            -- If we have a touch menu: Update menu entries,
                            -- when called from a menu
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        else
                            -- not all fields where entered
                            UIManager:show(InfoMessage:new{
                                text = _("Not all fields where entered!!!"),
                            })

                        end
                    end
                },
            },
        },
    }

    return edit_input
end

function ToonDl:Is_Ready(job_id,db_id)
    --print("Running isready")
    local sink = {}  
    socketutil:set_timeout()  
    local request = {  
        url     = ToonDl.serv_url .. "job_info/" .. job_id,  
        method  = "GET",  
        headers = {  
            ["Authorization"] = "Bearer "..ToonDl.api_key
        },  
        sink    = ltn12.sink.table(sink),  
    }  
    local code, headers, status = socket.skip(1, http.request(request))  
    print(code, tostring(status))
    local content = table.concat(sink)
    socketutil:reset_timeout()  
    --content = table.concat(sink)
    if code == 200 then
        local json, err = rapidjson.decode(content)  
        if json then  
            --print("Json parsed succesfully")
            if json.progress == 100 then
                print("READY")
                local files = json.files
                for i,v in ipairs(files) do
                    print(v)
                    local dl_url = ToonDl.serv_url .. "files/" .. v
                    local dl_path = ToonDl.home_dir .. "/" .. v
                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)  
                    
                    -- Download the file  
                    code, headers, status = socket.skip(1, http.request{  
                        url     = dl_url, 
                        headers = {  
                            ["Authorization"] = "Bearer "..ToonDl.api_key
                        },  
                        sink    = ltn12.sink.file(io.open(dl_path, "w")),  
                    })  
                    socketutil:reset_timeout()  

                    if code == 200 then  
                        print("File downloaded successfully")
                    else  
                        print("Download failed:", status or code)  
                    end

                end
                -- update db
                local ende = ToonDl.conn:rowexec("SELECT End_ep FROM Toons WHERE Id =".. tostring(db_id))
                local stmt = ToonDl.conn:prepare("UPDATE Toons  SET Start_ep=?,End_ep=? WHERE Id =?")
                stmt:reset():bind(tonumber(ende+1),tonumber(ende)+11,db_id):step()

                --rm job
                sink = {}  
                socketutil:set_timeout()  
                request = {  
                    url     = ToonDl.serv_url .. "delete_job/" .. job_id,  
                    method  = "DELETE",  
                    headers = {  
                        ["Authorization"] = "Bearer "..ToonDl.api_key
                    },  
                    sink    = ltn12.sink.table(sink),  
                }  
                code, headers, status = socket.skip(1, http.request(request))  
                print("Deletion status: "..tostring(status))

                UIManager:show(InfoMessage:new{
                    text = _("Download finished"),
                })
                return true
            elseif json.progress == -1 then
                UIManager:show(InfoMessage:new{
                    text = _("There was an server error"),
                })
                sink = {}  
                socketutil:set_timeout()  
                request = {  
                    url     = ToonDl.serv_url .. "delete_job/" .. job_id,  
                    method  = "DELETE",  
                    headers = {  
                        ["Authorization"] = "Bearer "..ToonDl.api_key
                    },  
                    sink    = ltn12.sink.table(sink),  
                }  
                code, headers, status = socket.skip(1, http.request(request))  
                print("Failed job deletion status: "..tostring(status))
            else
                UIManager:scheduleIn(5,function ()
                    print("Still waiting for dl...")
                    ToonDl:Is_Ready(job_id,db_id)
                end)
            end
        else
            UIManager:show(InfoMessage:new{
                text = _("Error while checking progress"),
            })
        end

    else
        UIManager:show(InfoMessage:new{
            text = _("Error while checking progress, got: "..tostring(status)),
        })
    end
end

function ToonDl:DownScreen(id)
    --print(id)
    local name,ende,starte,COMICurl = ToonDl.conn:rowexec("SELECT Name,End_ep,Start_ep,Url FROM Toons WHERE Id =".. tostring(id))
    local Download_comic = KeyValuePage:new{
        title = "Downlad Page for " .. name,
        kv_pairs = {
            {"Start ep", tostring(tonumber(starte))},
            {"End ep", tostring(tonumber(ende))},
            "----------------------------",
            {"Download","",callback = function ()
                NetworkMgr:turnOnWifiAndWaitForConnection(function () -- cant split this into functions, cause its async and i dont want to learn await or something in lua
                    print("connected")
                    

                    ----------POST JOB TO SRV------------------------
                    local body = {
                        url = COMICurl,
                        end_ep = tonumber(ende),
                        start_ep = tonumber(starte),
                    }

                    local body_json = rapidjson.encode(body)

                    local sink = {}  
                    socketutil:set_timeout()  
                    local request = {  
                        url = ToonDl.serv_url .. "post_job",  
                        method = "POST",  
                        headers = {  
                            ["Content-Type"] = "application/json",  
                            ["Content-Length"] = #body_json,  
                            ["Authorization"] = "Bearer "..ToonDl.api_key
                        },  
                        source = ltn12.source.string(body_json),  
                        sink = ltn12.sink.table(sink),  
                    }  
                    local code, headers, status = socket.skip(1, http.request(request))  
                    if code == 202 then
                        socketutil:reset_timeout()  
                        local content = table.concat(sink)
                        --DECODE RESPONSE TO GET JOB ID
                        local json, err = rapidjson.decode(content)  
                        if json then  
                            print("Json parsed succesfully")
                            print("job id: ",json.job_id)

                            ----------------START JOB ON SRV--------------
                            sink = {}  
                            socketutil:set_timeout()  
                            request = {  
                                url     = ToonDl.serv_url .. "start_job/"..json.job_id,  
                                method  = "GET",  
                                headers = {  
                                    ["Authorization"] = "Bearer "..ToonDl.api_key
                                },  
                                sink    = ltn12.sink.table(sink),  
                            }  
                            code, headers, status = socket.skip(1, http.request(request))  
                            socketutil:reset_timeout()  
                            --content = table.concat(sink)
                            if code == 200 then
                                UIManager:show(InfoMessage:new{
                                    text = _("Download started, now please wait"),
                                })
                                local curr_sec = time.now() + time.s(5)
                                ToonDl:Is_Ready(json.job_id,id)
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("There was some error, cant download"),
                                })
                            end


                        else  
                            logger.warn("failed to decode json data", err)  
                            UIManager:show(InfoMessage:new{
                                    text = _("Failed to decode json!!!"),
                                })
                            print("error in json")
                        end 
                    else
                        local print_status = ""
                        if status == nil then
                            print_status = "Couldn't connect to the server"
                        else
                            print_status = tostring(status)
                        end

                        UIManager:show(InfoMessage:new{
                                    text = _("Got "..print_status),
                                })
                    end
                    



                    --[[
                    local sink = {}  
                    socketutil:set_timeout()  
                    local request = {  
                        url     = "http://localhost:8080/job_info/31",  
                        method  = "GET",  
                        sink    = ltn12.sink.table(sink),  
                    }  
                    local code, headers, status = socket.skip(1, http.request(request))  
                    socketutil:reset_timeout()  
                    local content = table.concat(sink)
                    print(content)

                    local json, err = rapidjson.decode(content)  

                    if json then  
                        print("Json parsed succesfully")
                        print(json.id, json.progress)

                    else  
                        logger.warn("failed to decode json data", err)  
                        print("error in json")
                    end  

                    ]]--

                end)
            end},
            {"","Edit comic",callback=function ()
                local es = ToonDl:edit_comic_screen(id)
                UIManager:show(es)
            end},
            {"","Delete comic", callback = function ()
                ToonDl.conn:rowexec("DELETE FROM Toons WHERE Id =".. tostring(id))
            end}
        },
    }
    UIManager:show(Download_comic)
end


function ToonDl:UpdateJson()
    local body = {
        api_key = ToonDl.api_key,
        serv_url = ToonDl.serv_url,
        dl_dir = ToonDl.home_dir,
    }

    local body_json = rapidjson.encode(body)
    local util = require("util")
    local ok, err = util.writeToFile(body_json, get_script_dir().."config.json")  
    if ok then  
        print( "File written successfully" )
    else  
       print( "File NOT written successfully" )
    end
end

function ToonDl:MainScreen()
    local how_many = ToonDl.conn:rowexec("SELECT COUNT(*) FROM Toons")

    local results = ToonDl.conn:exec("SELECT Name,Start_ep,Id FROM Toons")

    local rpairs = {
        {"Added comics", tostring(tonumber(how_many))},
        "----------------------------",
    }

    local i = 1
    while i<=how_many do
        --print(results.Name[i],results.Start_ep[i],results.Id[i])
        --print(tonumber(results.Id[i]))
        local id_sql = tonumber(results.Id[i])
        local down_num = 0
        if not (tonumber(results.Start_ep[i]) == 0) then
            down_num = tonumber(results.Start_ep[i]) -1
        end
        table.insert(rpairs,{results.Name[i],"Down "..tostring(down_num).."eps",callback = function () ToonDl:DownScreen(id_sql) end})
        i= i+1
    end
    table.insert(rpairs,"----------------------------")
    table.insert(rpairs,{"","Add comic",callback = function ()
            --here give text input
            UIManager:show(url_input)
        end})

    table.insert(rpairs,{"","Settings",callback = function ()
        local settings = KeyValuePage:new{
            title = "Settings",
            kv_pairs = {
                {"Download path",ToonDl.home_dir,hold_callback = function ()
                    require("ui/downloadmgr"):new{
                        title = _("Choose download directory"),
                        onConfirm = function(path)
                            --logger.dbg("set download directory to", path)
                            --G_reader_settings:saveSetting("download_dir", path)
                            print("new path:",path)
                            ToonDl.home_dir = path
                            ToonDl:UpdateJson()
                            UIManager:nextTick(function()
                                -- reinitialize dialog
                            end)
                        end,
                    }:chooseDir()
                end},
                {"Api key","long press to change"},
                {"Eps per file",10},
                {"Server url",ToonDl.serv_url},
            },
        }
        UIManager:show(settings)
    end})
    
    local List_comics = KeyValuePage:new{
        title = "Webtoon dl",
        kv_pairs = rpairs,
    }

    
    UIManager:show(List_comics)
end

function ToonDl:addToMainMenu(menu_items)
    menu_items.ToonDl_world = {
        text = _("Webtoon"),
        -- in which menu this should be appended
        sorting_hint = "search",
        -- a callback when tapping
        callback = function()
            --UIManager:show(InfoMessage:new{    text = _("Hello, plugin world"),})
            ToonDl:MainScreen()
        end,
    }
end


return ToonDl
