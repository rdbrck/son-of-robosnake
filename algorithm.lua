local algorithm = {}


-- Lua optimization: any functions from another module called more than once
-- are faster if you create a local reference to that function.
local DEBUG = ngx.DEBUG
local log = ngx.log
local mdist = util.mdist
local n_complement = util.n_complement
local prettyCoords = util.prettyCoords
local printWorldMap = util.printWorldMap


--[[
    PRIVATE METHODS
]]


--- Clones a table recursively.
--- Modified to ignore metatables because we don't use them.
-- @param table t The source table
-- @return table The copy of the table
-- @see https://gist.github.com/MihailJP/3931841
local function deepcopy(t) -- deep-copy a table
    if type(t) ~= "table" then return t end
    local target = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            target[k] = deepcopy(v)
        else
            target[k] = v
        end
    end
    return target
end


--- Returns true if a square is safe to move into, false otherwise
-- @param string v The value of a particular tile on the grid
-- @param boolean failsafe If true, don't consider if the neighbour is safe or not
-- @return boolean
local function isSafeSquare( v, failsafe )
    if failsafe then
        return true
    elseif HEAD_ON_NECK_DETECTION then
        return v == '.' or v == 'O' or v == '*' or v == '@'
    else
        return v == '.' or v == 'O' or v == '*'
    end
end


--- Returns true if a square is currently occupied, false otherwise
-- @param string v The value of a particular tile on the grid
-- @return boolean
local function isSafeSquareFloodfill( v )
    return v == '.' or v == 'O'
end


--- "Floods" the grid in order to find out how many squares are accessible to us
--- This ruins the grid, make sure you always work on a deepcopy of the grid!
-- @param table pos The starting position
-- @param table grid The game grid
-- @param int numSafe The number of free squares from the last iteration
-- @param int len The maximum depth of the flood fill
-- @return int The number of free squares on the grid
-- @see https://en.wikipedia.org/wiki/Flood_fill#Stack-based_recursive_implementation_.28four-way.29
local function floodfill( pos, grid, numSafe, len )
    if numSafe >= len then
        return numSafe
    end
    local y = pos[ 'y' ]
    local x = pos[ 'x' ]
    if isSafeSquareFloodfill( grid[y][x] ) then
        grid[y][x] = 1
        numSafe = numSafe + 1
        local n = algorithm.neighbours( pos, grid )
        for i = 1, #n do
            numSafe = floodfill( n[i], grid, numSafe, len )
        end
    end
    return numSafe
end


--- The heuristic function used to determine board/gamestate score
-- @param grid The game grid
-- @param state The game state
-- @param my_moves Table containing my possible moves
-- @param enemy_moves Table containing enemy's possible moves
local function heuristic( grid, state, my_moves, enemy_moves )

    -- Default board score
    local score = 0

    -- Handle head-on-neck collisions.
    if
        HEAD_ON_NECK_DETECTION == true
        and state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == state[ 'enemy' ][ 'body' ][ 'data' ][2][ 'x' ]
        and state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == state[ 'enemy' ][ 'body' ][ 'data' ][2][ 'y' ]
        and state[ 'me' ][ 'body' ][ 'data' ][2][ 'x' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ]
        and state[ 'me' ][ 'body' ][ 'data' ][2][ 'y' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ]
    then
        log( DEBUG, 'Head-on-neck collision!' )
        if #state[ 'me' ][ 'body' ][ 'data' ] > #state[ 'enemy' ][ 'body' ][ 'data' ] then
            log( DEBUG, 'I am bigger and win!' )
            return 2147483647  -- safe to short circuit as we are in close proximity to the enemy
        elseif #state[ 'me' ][ 'body' ][ 'data' ] < #state[ 'enemy' ][ 'body' ][ 'data' ] then
            log( DEBUG, 'I am smaller and lose.' )
            return -2147483648
        else
            -- do not use negative infinity here.
            -- draws are better than losing because the bounty cannot be claimed without a clear victor.
            log( DEBUG, "It's a draw." )
            return -2147483647  -- one less than max int size
        end
    end
    
    -- Handle head-on-head collisions.
    if
        state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ]
        and state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ]
    then
        log( DEBUG, 'Head-on-head collision!' )
        if #state[ 'me' ][ 'body' ][ 'data' ] > #state[ 'enemy' ][ 'body' ][ 'data' ] then
            log( DEBUG, 'I am bigger and win!' )
            if HEAD_ON_NECK_DETECTION == true then
                return 2147483647  -- safe to short circuit as we are in close proximity to the enemy
            else
                score = score + 2147483647
            end
        elseif #state[ 'me' ][ 'body' ][ 'data' ] < #state[ 'enemy' ][ 'body' ][ 'data' ] then
            log( DEBUG, 'I am smaller and lose.' )
            return -2147483648
        else
            -- do not use negative infinity here.
            -- draws are better than losing because the bounty cannot be claimed without a clear victor.
            log( DEBUG, "It's a draw." )
            return -2147483647  -- one less than max int size
        end
    end
    
    if HEAD_ON_NECK_DETECTION == true then
        -- Handle head-on-body collisions
        -- Normally, this should never occur due to filtering out grid moves that contain a snake body.
        -- HOWEVER, if we attempt a head-on-neck attack and the enemy doesn't also try and attack us at the same time,
        -- we could end up in the same square as one of its' body parts (and vice versa). So we have to explicitly test
        -- for this case now.
        local me_in_me = false
        local me_in_enemy = false
        local enemy_in_me = false
        local enemy_in_enemy = false
        for k, v in ipairs( state[ 'enemy' ][ 'body' ][ 'data' ] ) do
            if state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == v[ 'x' ] and state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == v[ 'y' ] then
                me_in_enemy = true
            end
            if k > 1 and state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ] == v[ 'x' ] and state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ] == v[ 'y' ] then
                enemy_in_enemy = true
            end
        end
        
        for k, v in ipairs( state[ 'me' ][ 'body' ][ 'data' ] ) do
            if state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ] == v[ 'x' ] and state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ] == v[ 'y' ] then
                enemy_in_me = true
            end
            if k > 1 and state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == v[ 'x' ] and state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == v[ 'y' ] then
                me_in_me = true
            end
        end
        
        if ( me_in_me or me_in_enemy ) and ( enemy_in_me or enemy_in_enemy ) then
            log( DEBUG, "Both me and the enemy ran into a snake body." )
            return -2147483647  -- one less than max int size
        elseif ( me_in_me or me_in_enemy ) and not ( enemy_in_me or enemy_in_enemy ) then
            log( DEBUG, 'I ran into a snake body.' )
            return -2147483648
        elseif ( enemy_in_me or enemy_in_enemy ) and not ( me_in_me or me_in_enemy ) then
            log( DEBUG, 'Enemy ran into a snake body.' )
            score = score + 2147483647
        end
    end

    -- My win/loss conditions
    if #my_moves == 0 then
        log( DEBUG, 'I am trapped.' )
        return -2147483648
    end
    if state[ 'me' ][ 'health' ] <= 0 then
        log( DEBUG, 'I am out of health.' )
        return -2147483648
    end
    
    -- get food from grid since it's a pain to update state every time we pass through minimax
    local food = {}
    for y = 1, #grid do
        for x = 1, #grid[y] do
            if grid[y][x] == 'O' then
                table.insert( food, { x = x, y = y } )
            end
        end
    end
    
    -- The floodfill heuristic should never be used alone as it will always avoid food!
    -- The reason for this is that food increases our length by one, causing one less
    -- square on the board to be available for movement.
    
    -- Run a floodfill from my current position, to find out:
    -- 1) How many squares can I reach from this position?
    -- 2) What percentage of the board does that represent?
    local floodfill_grid = deepcopy( grid )
    floodfill_grid[ state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] ][ state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] ] = '.'
    local floodfill_depth = ( 2 * #state[ 'me' ][ 'body' ][ 'data' ] ) + #food
    local accessible_squares = floodfill( state[ 'me' ][ 'body' ][ 'data' ][1], floodfill_grid, 0, floodfill_depth )
    local percent_accessible = accessible_squares / ( #grid * #grid[1] )
    
    -- If the number of squares I can see from my current position is less than my length
    -- then moving to this position *may* trap and kill us, and should be avoided if possible
    if accessible_squares <= #state[ 'me' ][ 'body' ][ 'data' ] then
        log( DEBUG, 'I smell a trap!' )
        return -9999999 * ( 1 / percent_accessible )
    end

    
    -- Enemy win/loss conditions
    if #enemy_moves == 0 then
        log( DEBUG, 'Enemy is trapped.' )
        score = score + 2147483647
    end
    if state[ 'enemy' ][ 'health' ] <= 0 then
        log( DEBUG, 'Enemy is out of health.' )
        score = score + 2147483647
    end
    
    -- Run a floodfill from the enemy's current position, to find out:
    -- 1) How many squares can the enemy reach from this position?
    -- 2) What percentage of the board does that represent?
    local enemy_floodfill_grid = deepcopy( grid )
    enemy_floodfill_grid[ state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ] ][ state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ] ] = '.'
    local enemy_floodfill_depth = ( 2 * #state[ 'enemy' ][ 'body' ][ 'data' ] ) + #food
    local enemy_accessible_squares = floodfill( state[ 'enemy' ][ 'body' ][ 'data' ][1], enemy_floodfill_grid, 0, enemy_floodfill_depth )
    local enemy_percent_accessible = enemy_accessible_squares / ( #grid * #grid[1] )
    
    -- If the number of squares the enemy can see from their current position is less than their length
    -- then moving to this position *may* trap and kill them, and should be avoided if possible
    if enemy_accessible_squares <= #state[ 'enemy' ][ 'body' ][ 'data' ] then
        log( DEBUG, 'Enemy might be trapped!' )
        score = score + 9999999
    end
    
    -- If there's food on the board, and I'm hungry, go for it
    -- If I'm not hungry, ignore it
    local foodWeight = 0
    if #food <= LOW_FOOD then
        foodWeight = 200 - ( 2 * state[ 'me' ][ 'health' ] )
    else
        if state[ 'me' ][ 'health' ] <= HUNGER_HEALTH or #state[ 'me' ][ 'body' ][ 'data' ] < 4 then
            foodWeight = 100 - state[ 'me' ][ 'health' ]
        end
    end
    log( DEBUG, 'Food Weight: ' .. foodWeight )
    if foodWeight > 0 then
        for i = 1, #food do
            local dist = mdist( state[ 'me' ][ 'body' ][ 'data' ][1], food[i] )
            -- "i" is used in the score so that two pieces of food that 
            -- are equal distance from me do not have identical weighting
            score = score - ( dist * foodWeight ) - i
            log( DEBUG, string.format( 'Food [%s,%s], distance %s, score %s', food[i][ 'x' ], food[i][ 'y' ], dist, ( dist * foodWeight ) - i ) )
        end
    end

    -- Hang out near the enemy's head
    local aggressiveWeight = 100
    if #food <= LOW_FOOD then
        aggressiveWeight = state[ 'me' ][ 'health' ]
    end
    local kill_squares = algorithm.neighbours( state[ 'enemy' ][ 'body' ][ 'data' ][1], grid )
    local enemy_last_direction = util.direction( state[ 'enemy' ][ 'body' ][ 'data' ][2], state[ 'enemy' ][ 'body' ][ 'data' ][1] )
    for i = 1, #kill_squares do
        local dist = mdist( state[ 'me' ][ 'body' ][ 'data' ][1], kill_squares[i] )
        local direction = util.direction( state[ 'enemy' ][ 'body' ][ 'data' ][1], kill_squares[i] )
        if direction == enemy_last_direction then
            score = score - ( dist * ( 2 * aggressiveWeight ) )
            log( DEBUG, string.format( 'Prime head target [%s,%s], distance %s, score %s', kill_squares[i][ 'x' ], kill_squares[i][ 'y' ], dist, dist * ( 2 * aggressiveWeight ) ) )
        else
            score = score - ( dist * aggressiveWeight )
            log( DEBUG, string.format( 'Head target [%s,%s], distance %s, score %s', kill_squares[i][ 'x' ], kill_squares[i][ 'y' ], dist, dist * aggressiveWeight ) )
        end
    end
    
    -- Avoid the edge of the game board
    if
        state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == 1
        or state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == #grid[1]
        or state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == 1
        or state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == #grid
    then
        score = score - 25000
    end
     
    -- Hang out near the center
    -- Temporarily Disabled
    --[[local center_x = math.ceil( #grid[1] / 2 )
    local center_y = math.ceil( #grid / 2 )
    local dist = mdist( state[ 'me' ][ 'body' ][ 'data' ][1], { x = center_x, y = center_y } )
    score = score - (dist * 100)
    log( DEBUG, string.format('Center distance %s, score %s', dist, dist*100 ) )]]
    
 
    log( DEBUG, 'Original score: ' .. score )
    log( DEBUG, 'Percent accessible: ' .. percent_accessible )
    if score < 0 then
        score = score * (1/percent_accessible)
    elseif score > 0 then
        score = score * percent_accessible
    end
    
    log( DEBUG, 'Score: ' .. score )

    return score
end


--[[
    PUBLIC METHODS
]]

--- Returns the set of all coordinate pairs on the board that are adjacent to the given position
-- @param table pos The source coordinate pair
-- @param table grid The game grid
-- @param boolean failsafe If true, don't consider if the neighbour is safe or not
-- @return table The neighbours of the source coordinate pair
function algorithm.neighbours( pos, grid, failsafe )
    local neighbours = {}
    local north = { x = pos[ 'x' ], y = pos[ 'y' ] - 1 }
    local south = { x = pos[ 'x' ], y = pos[ 'y' ] + 1 }
    local east = { x = pos[ 'x' ] + 1, y = pos[ 'y' ] }
    local west = { x = pos[ 'x' ] - 1, y = pos[ 'y' ] }
    
    local height = #grid
    local width = #grid[1]
    
    if north[ 'y' ] > 0 and north[ 'y' ] <= height and isSafeSquare( grid[ north[ 'y' ] ][ north[ 'x' ] ], failsafe ) then
        table.insert( neighbours, north )
    end
    if south[ 'y' ] > 0 and south[ 'y' ] <= height and isSafeSquare( grid[ south[ 'y' ] ][ south[ 'x' ] ], failsafe ) then
        table.insert( neighbours, south )
    end
    if east[ 'x' ] > 0 and east[ 'x' ] <= width and isSafeSquare( grid[ east[ 'y' ] ][ east[ 'x' ] ], failsafe ) then
        table.insert( neighbours, east )
    end
    if west[ 'x' ] > 0 and west[ 'x' ] <= width and isSafeSquare( grid[ west[ 'y' ] ][ west[ 'x' ] ], failsafe ) then
        table.insert( neighbours, west )
    end
    
    return neighbours
end


--- The Alpha-Beta pruning algorithm.
--- When we reach maximum depth, calculate a "score" (heuristic) based on the game/board state.
--- As we come back up through the call stack, at each depth we toggle between selecting the move
--- that generates the maximum score, and the move that generates the minimum score. The idea is
--- that we want to maximize the score (pick the move that puts us in the best position), and that
--- our opponent wants to minimize the score (pick the move that puts us in the worst position).
-- @param grid The game grid
-- @param state The game state
-- @param depth The current recursion depth
-- @param alpha The highest-ranked board score at the current depth, from my PoV
-- @param beta The lowest-ranked board score at the current depth, from my PoV
-- @param alphaMove The best move at the current depth
-- @param betaMove The worst move at the current depth
-- @param maximizingPlayer True if calculating alpha at this depth, false if calculating beta
-- @param prev_grid The game grid from the previous depth
-- @param prev_enemy_moves The enemy move list from the previous depth
-- @return alpha/beta The alpha or beta board score
-- @return alphaMove/betaMove The alpha or beta next move
function algorithm.alphabeta( grid, state, depth, alpha, beta, alphaMove, betaMove, maximizingPlayer, prev_grid, prev_enemy_moves )

    log( DEBUG, 'Depth: ' .. depth )

    local moves = {}
    local my_moves = algorithm.neighbours( state[ 'me' ][ 'body' ][ 'data' ][1], grid )
    local enemy_moves = {}
    if maximizingPlayer then
        enemy_moves = algorithm.neighbours( state[ 'enemy' ][ 'body' ][ 'data' ][1], grid )
    else
        enemy_moves = prev_enemy_moves
    end
    
    if maximizingPlayer then
        moves = my_moves
        log( DEBUG, string.format( 'My Turn. Position: %s Possible moves: %s', prettyCoords( state[ 'me' ][ 'body' ][ 'data' ] ), prettyCoords( moves ) ) )
    else
        moves = enemy_moves
        log( DEBUG, string.format( 'Enemy Turn. Position: %s Possible moves: %s', prettyCoords( state[ 'enemy' ][ 'body' ][ 'data' ] ), prettyCoords( moves ) ) )
    end
    
    if
        depth == MAX_RECURSION_DEPTH or
        
        -- short circuit win/loss conditions
        #moves == 0 or
        state[ 'me' ][ 'health' ] <= 0 or
        state[ 'enemy' ][ 'health' ] <= 0
    then
        if depth == MAX_RECURSION_DEPTH then
            log( DEBUG, 'Reached MAX_RECURSION_DEPTH.' )
        else
            log( DEBUG, 'Reached endgame state.' )
        end
        return heuristic( grid, state, my_moves, enemy_moves )
    end
    
    
    if HEAD_ON_NECK_DETECTION == true then
        if (
            -- We can only consider a head-on-head collision if we've executed both player's moves in minimax!
            depth % 2 == 0
            and state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ]
            and state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ]
        ) or
        (
            -- We can only consider a head-on-neck collision if we've executed both player's moves in minimax!
            depth % 2 == 0
            and state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == state[ 'enemy' ][ 'body' ][ 'data' ][2][ 'x' ]
            and state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == state[ 'enemy' ][ 'body' ][ 'data' ][2][ 'y' ]
            and state[ 'me' ][ 'body' ][ 'data' ][2][ 'x' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ]
            and state[ 'me' ][ 'body' ][ 'data' ][2][ 'y' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ]
        )
        then
            log( DEBUG, 'Reached endgame state.' )
            return heuristic( grid, state, my_moves, enemy_moves )
        end
        
        if depth % 2 == 0 then
            for k, v in ipairs( state[ 'enemy' ][ 'body' ][ 'data' ] ) do
                if state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == v[ 'x' ] and state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == v[ 'y' ] then
                    log( DEBUG, 'Reached endgame state.' )
                    return heuristic( grid, state, my_moves, enemy_moves )
                end
                if k > 1 and state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ] == v[ 'x' ] and state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ] == v[ 'y' ] then
                    log( DEBUG, 'Reached endgame state.' )
                    return heuristic( grid, state, my_moves, enemy_moves )
                end
            end
            
            for k, v in ipairs( state[ 'me' ][ 'body' ][ 'data' ] ) do
                if state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ] == v[ 'x' ] and state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ] == v[ 'y' ] then
                    log( DEBUG, 'Reached endgame state.' )
                    return heuristic( grid, state, my_moves, enemy_moves )
                end
                if k > 1 and state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == v[ 'x' ] and state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == v[ 'y' ] then
                    log( DEBUG, 'Reached endgame state.' )
                    return heuristic( grid, state, my_moves, enemy_moves )
                end
            end
        end
        
    else
        if (
            state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ]
            and state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] == state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ]
        )
        then
            log( DEBUG, 'Reached endgame state.' )
            return heuristic( grid, state, my_moves, enemy_moves )
        end
    end
  
    if maximizingPlayer then
        for i = 1, #moves do
                        
            -- Update grid and coords for this move
            log( DEBUG, string.format( 'My move: [%s,%s]', moves[i][ 'x' ], moves[i][ 'y' ] ) )
            local new_grid = deepcopy( grid )
            local new_state = deepcopy( state )
            local eating = false
            
            -- if next tile is food we are eating/healing, otherwise lose 1 health
            if new_grid[ moves[i][ 'y' ] ][ moves[i][ 'x' ] ] == 'O' then
                eating = true
                new_state[ 'me' ][ 'health' ] = 100
            else
                new_state[ 'me' ][ 'health' ] = new_state[ 'me' ][ 'health' ] - 1
            end
            
            -- remove tail from map ONLY if not growing
            local length = #new_state[ 'me' ][ 'body' ][ 'data' ]
            if
              length > 1
              and
              (
                new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'x' ] == new_state[ 'me' ][ 'body' ][ 'data' ][ length - 1 ][ 'x' ]
                and new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'y' ] == new_state[ 'me' ][ 'body' ][ 'data' ][ length - 1 ][ 'y' ]
              )
            then
                -- do nothing
            else
                new_grid[ new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'y' ] ][ new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'x' ] ] = '.'
            end
            
            -- always remove tail from state
            table.remove( new_state[ 'me' ][ 'body' ][ 'data' ] )
            
            -- move head in state and on grid
            if length > 1 then
                new_grid[ new_state[ 'me' ][ 'body' ][ 'data' ][1][ 'y' ] ][ new_state[ 'me' ][ 'body' ][ 'data' ][1][ 'x' ] ] = '#'
            end
            table.insert( new_state[ 'me' ][ 'body' ][ 'data' ], 1, moves[i] )
            new_grid[ moves[i][ 'y' ] ][ moves[i][ 'x' ] ] = '@'
            
            -- if eating add to the snake's body
            if eating then
                table.insert(
                    new_state[ 'me' ][ 'body' ][ 'data' ],
                    {
                        x = new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'x' ],
                        y = new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'y' ]
                    }
                )
                eating = false
            end
            
            -- mark if the tail is a safe square or not
            local length = #new_state[ 'me' ][ 'body' ][ 'data' ]
            if
              length > 1
              and
              (
                new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'x' ] == new_state[ 'me' ][ 'body' ][ 'data' ][ length - 1 ][ 'x' ]
                and new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'y' ] == new_state[ 'me' ][ 'body' ][ 'data' ][ length - 1 ][ 'y' ]
              )
            then
                new_grid[ new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'y' ] ][ new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'x' ] ] = '#'
            else
                new_grid[ new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'y' ] ][ new_state[ 'me' ][ 'body' ][ 'data' ][ length ][ 'x' ] ] = '*'
            end
            
            printWorldMap( new_grid )
            
            local newAlpha = algorithm.alphabeta( new_grid, new_state, depth + 1, alpha, beta, alphaMove, betaMove, false, grid, enemy_moves )
            if newAlpha > alpha then
                alpha = newAlpha
                alphaMove = moves[i]
            end
            if beta <= alpha then break end
        end
        return alpha, alphaMove
    else
        for i = 1, #moves do
            
            -- Update grid and coords for this move
            log( DEBUG, string.format( 'Enemy move: [%s,%s]', moves[i][ 'x' ], moves[i][ 'y' ] ) )
            local new_grid = deepcopy( grid )
            local new_state = deepcopy( state )
            local eating = false
            
            -- if next tile is food we are eating/healing, otherwise lose 1 health
            if prev_grid[ moves[i][ 'y' ] ][ moves[i][ 'x' ] ] == 'O' then
                eating = true
                new_state[ 'enemy' ][ 'health' ] = 100
            else
                new_state[ 'enemy' ][ 'health' ] = new_state[ 'enemy' ][ 'health' ] - 1
            end
            
            -- remove tail from map ONLY if not growing
            local length = #new_state[ 'enemy' ][ 'body' ][ 'data' ]
            if
              length > 1
              and
              (
                new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'x' ] == new_state[ 'enemy' ][ 'body' ][ 'data' ][ length - 1 ][ 'x' ]
                and new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'y' ] == new_state[ 'enemy' ][ 'body' ][ 'data' ][ length - 1 ][ 'y' ]
              )
            then
                -- do nothing
            else
                new_grid[ new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'y' ] ][ new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'x' ] ] = '.'
            end
            
            -- always remove tail from state
            table.remove( new_state[ 'enemy' ][ 'body' ][ 'data' ] )
            
            -- move head in state and on grid
            if length > 1 then
                new_grid[ new_state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'y' ] ][ new_state[ 'enemy' ][ 'body' ][ 'data' ][1][ 'x' ] ] = '#'
            end
            table.insert( new_state[ 'enemy' ][ 'body' ][ 'data' ], 1, moves[i] )
            new_grid[ moves[i][ 'y' ] ][ moves[i][ 'x' ] ] = '@'
            
            -- if eating add to the snake's body
            if eating then
                table.insert(
                    new_state[ 'enemy' ][ 'body' ][ 'data' ],
                    {
                        x = new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'x' ],
                        y = new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'y' ]
                    }
                )
                eating = false
            end
            
            -- mark if the tail is a safe square or not
            local length = #new_state[ 'enemy' ][ 'body' ][ 'data' ]
            if
              length > 1
              and
              (
                new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'x' ] == new_state[ 'enemy' ][ 'body' ][ 'data' ][ length - 1 ][ 'x' ]
                and new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'y' ] == new_state[ 'enemy' ][ 'body' ][ 'data' ][ length - 1 ][ 'y' ]
              )
            then
                new_grid[ new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'y' ] ][ new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'x' ] ] = '#'
            else
                new_grid[ new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'y' ] ][ new_state[ 'enemy' ][ 'body' ][ 'data' ][ length ][ 'x' ] ] = '*'
            end
            
            printWorldMap( new_grid )
            
            local newBeta = algorithm.alphabeta( new_grid, new_state, depth + 1, alpha, beta, alphaMove, betaMove, true, {}, {} )
            if newBeta < beta then
                beta = newBeta
                betaMove = moves[i]
            end
            if beta <= alpha then break end
        end
        return beta, betaMove
    end
  
end


return algorithm
