{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, FlexibleContexts, TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE QuasiQuotes #-}


module Examples.Auctions.ChooseReservePrice where


import OpenGames.Engine.Engine
import OpenGames.Preprocessor
import Examples.Auctions.AuctionSupportFunctions
import Examples.Auctions.SimultaneousBidAuction

----------
-- A Model
----------
-- 0. Auxiliary function

revenueAuctioneer :: Num v =>  [(n, v)] -> v
revenueAuctioneer ls = sum $ fmap snd ls 

auctioneerValueSpace = [0,20..100]
---------------------
-- 1 The actual games

-- Draws a value and creates a pair of _value_ _name_
setReservePrice kPrice kSlots valueSpaceAuctioneer valueSpace1 valueSpace2 actionSpace1 actionSpac2 = [opengame|

    inputs    :   ;
    feedback  :   ;

    :-----:
    inputs    :   ;
    feedback  :   ;
    operation : dependentDecision "auctioneer" (const valueSpaceAuctioneer) ;
    outputs   : reservePrice ;
    returns   : revenueAuctioneer payments ;

    inputs    : reservePrice  ;
    feedback  :   ;
    operation : bidding2ReservePrice kPrice kSlots valueSpace1 valueSpace2 actionSpace1 actionSpac2;
    outputs   : payments ;
    returns   :  ;
    :-----:

    outputs   :  ;
    returns   :  ;
  |]

-- B Analysis
----------------
-- 0. Strategies
stratAuctioneer x = pureAction x

stratTuple x = stratAuctioneer x ::- truthfulStrat

---------------
-- 1 Equilibria
-- 1.0 Eq. game with 3 players
equilibriumSetReservePrice kPrice kSlots valueSpaceAuctioneer valueSpace1 valueSpace2 actionSpace1 actionSpace2 strat = evaluate (setReservePrice kPrice kSlots valueSpaceAuctioneer valueSpace1 valueSpace2 actionSpace1 actionSpace2) strat void


------------------------
-- 2 Interactive session

-- One object being auctioned off Once we exclude slots via lottery, and just auction off one slot, truthful bidding becomes an equilibrium
testReservePrice p = generateIsEq $ equilibriumSetReservePrice 2 1 auctioneerValueSpace values values values values (stratTuple p)



