local util = {}


-- Lua optimization: any functions from another module called more than once
-- are faster if you create a local reference to that function.
local LOG_ENABLED = LOGGER_ENABLED

local log = logger.log
local random = math.random

--[[
    PRIVATE METHODS
]]


--- Recursively compares two variables for equality.
-- @param mixed a The first var to compare
-- @param mixed b The second var to compare
-- @return boolean True if equal, False if not
-- @see https://github.com/vadi2/mudlet-lua/blob/2630cbeefc3faef3079556cb06459d1f53b8f842/lua/Other.lua#L467
local function _comp( a, b )
    if type( a ) ~= type( b ) then return false end
    if type( a ) == 'table' then
        for k, v in pairs( a ) do
            if not b[k] then return false end
            if not _comp( v, b[k] ) then return false end
        end
    else
        if a ~= b then return false end
    end
    return true
end



--[[
    PUBLIC METHODS
]]


--- Generates insults. Those less or eq to 40 characters
-- are readable on the official game board.
-- @return a random insult
function util.taunt()
    local taunts = {
	"You are better at only one thing. Dying.",
        "Are you a CEO for equifax?",
        "Your snake is a little ssssssssssssucky.",
        "You are impossible to underestimate.",
        "You ninnyhammer.",
        "May your foot be itchy and arms short.",
        "Tech yourself before you wreck yourself",
        "Hey Dad, can you do THIS?",
        "Still better than Aleksiy's snake.",
        "Justin Bieber? Sorry, I ate him."
    }
    return taunts[ random( #taunts ) ]
end


--- Take the BattleSnake arena's state JSON and use it to create our own grid
-- @param gameState The arena's game state JSON
-- @return A 2D table with each cell mapped to food, snakes, etc.
function util.buildWorldMap( gameState )
    local log_id = ngx.ctx.log_id
    local INFO = "info." .. log_id
    local DEBUG = "debug." .. log_id    


    -- Generate the tile grid
    if LOG_ENABLED then log( DEBUG, 'Generating tile grid' ) end

    local grid = {}
    for y = 1, gameState[ 'height' ] do
        grid[ y ] = {}
        for x = 1, gameState[ 'width' ] do
            grid[ y ][ x ] = '.'
        end
    end
    
    -- Place food
    for i = 1, #gameState[ 'food' ][ 'data' ] do
        local food = gameState[ 'food' ][ 'data' ][i]
        grid[ food[ 'y' ] ][ food[ 'x' ] ] = 'O'

        if LOG_ENABLED then
            log( DEBUG, string.format( 'Placed food at [%s, %s]', food[ 'x' ], food[ 'y' ] ) )
        end

        local food_log = {
            game_id = log_id,
            width = gameState['width'],
            height = gameState[ 'height'],
            turn = gameState[ 'turn' ],
            who = "game",
            item = "food",
            coordinates = { x = food[ 'x' ], y = food[ 'y' ] }
        }

        if LOG_ENABLED then log( INFO , food_log ) end
    end
    
    -- Place living snakes
    for i = 1, #gameState[ 'snakes' ][ 'data' ] do
        local player = gameState[ 'snakes' ][ 'data' ][ i ]
        local length = #gameState[ 'snakes' ][ 'data' ][ i ][ 'body' ][ 'data' ]

        for j = 1, length do
            local snake = gameState[ 'snakes' ][ 'data' ][ i ][ 'body' ][ 'data' ][ j ]

            local snake_log = ({
                 health = player[ 'health' ],
                 game_id = log_id,
                 who = player[ 'id' ],
                 name = player[ 'name' ],
                 width = gameState['width'],
                 height = gameState[ 'height'],
                 turn = gameState[ 'turn' ],
                 length = length,
                 coordinates = { x = snake[ 'x' ], y = snake[ 'y' ] }
             })

            if j == 1 then
                grid[ snake[ 'y' ] ][ snake[ 'x' ] ] = '@'

                if LOG_ENABLED then
                    snake_log.item = "head"
                    log( INFO, snake_log )
                    log( DEBUG, string.format( 'Placed snake head at [%s, %s]', snake[ 'x' ], snake[ 'y' ] ) )
                end
            elseif j == length then
                if grid[ snake[ 'y' ] ][ snake[ 'x' ] ] ~= '@' and grid[ snake[ 'y' ] ][ snake[ 'x' ] ] ~= '#' then
                    grid[ snake[ 'y' ] ][ snake[ 'x' ] ] = '*'
                end

                if LOG_ENABLED then
                    snake_log.item = "tail"
                    log(INFO, snake_log)
                end

            else
                if grid[ snake[ 'y' ] ][ snake[ 'x' ] ] ~= '@' then
                    grid[ snake[ 'y' ] ][ snake[ 'x' ] ] = '#'
                end

                if LOG_ENABLED then
                    snake_log.item = "body"
                    log( INFO, snake_log )
                    log( DEBUG, string.format( 'Placed snake tail at [%s, %s]', snake[ 'x' ], snake[ 'y' ] ) )
                end
            end

        end
    end
    
    return grid
end


--- Calculates the direction, given a source and destination coordinate pair
-- @param table src The source coordinate pair
-- @param table dst The destination coordinate pair
-- @return string The name of the direction
function util.direction( src, dst )
    if dst[ 'x' ] == src[ 'x' ] + 1 and dst[ 'y' ] == src[ 'y' ] then
        return 'right'
    elseif dst[ 'x' ] == src[ 'x' ] - 1 and dst[ 'y' ] == src[ 'y' ] then
        return 'left'
    elseif dst[ 'x' ] == src[ 'x' ] and dst[ 'y' ] == src[ 'y' ] + 1 then
        return 'down'
    elseif dst[ 'x' ] == src[ 'x' ] and dst[ 'y' ] == src[ 'y' ] - 1 then
        return 'up'
    end
end


--- Calculates the manhattan distance between two coordinate pairs
-- @param table src The source coordinate pair
-- @param table dst The destination coordinate pair
-- @return int The distance between the pairs
function util.mdist( src, dst )
    local dx = math.abs( src[ 'x' ] - dst[ 'x' ] )
    local dy = math.abs( src[ 'y' ] - dst[ 'y' ] )
    return ( dx + dy )
end


--- Returns values of set1 that do not appear in set2
-- @param table set1 A table with values that may need removing
-- @param table set2 A table containing any values that need to be removed from set1
-- @return table Returns values of set1 that do not appear in set2
-- @see https://github.com/vadi2/mudlet-lua/blob/2630cbeefc3faef3079556cb06459d1f53b8f842/lua/TableUtils.lua#L332
function util.n_complement( set1, set2 )
    if not set1 and set2 then return false end

    local complement = {}

    for _, val1 in pairs( set1 ) do
        local insert = true
        for _, val2 in pairs( set2 ) do
            if _comp( val1, val2 ) then
                    insert = false
            end
        end
        if insert then table.insert( complement, val1 ) end
    end

    return complement
end


-- Prints out a table of coordinate pairs in a pretty manner.
-- @param table coords The table of coordinate pairs
-- @return string The pretty-printed coordinate pairs
function util.prettyCoords( coords )
    local str = ''
    for _, v in ipairs( coords ) do
        str = str .. string.format( '[%s,%s], ', v[ 'x' ], v[ 'y' ] )
    end
    return str
end


--- Prints the grid as an ASCII representation of the world map
-- @deprecated - Should be safe to remove, but let's keep incase
-- everything goes horribly horribly wrong.
-- @param grid The game grid
function util.printWorldMap( grid )
    return 

    --[[
    local str = "\n"
    for y = 1, #grid do
        for x = 1, #grid[ y ] do
            str = str .. grid[ y ][ x ]
        end
        if y < #grid then
            str = str .. "\n"
        end
    end
    log( DEBUG, str )
    --]]
end


return util
