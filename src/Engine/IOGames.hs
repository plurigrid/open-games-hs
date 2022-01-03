{-# LANGUAGE DataKinds, NamedFieldPuns, DisambiguateRecordFields, LambdaCase, RecordWildCards, OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

module Engine.IOGames
  ( IOOpenGame(..)
  , Agent(..)
  , DiagnosticInfoIO(..)
  , dependentDecisionIO
  , fromLens
  , fromFunctions
  , discount
  , Msg(..)
  , PlayerMsg(..)
  , SamplePayoffsMsg(..)
  , AverageUtilityMsg(..)
  , Diagnostics
  , logFuncSilent
  , logFuncTracing
  , logFuncStructured
  ) where


import System.Directory
import           GHC.Stack
import           Control.Monad.Reader
import           Data.Bifunctor
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S8
import           Data.Functor.Contravariant
import           Data.IORef
import           Debug.Trace
import qualified RIO
import           RIO (RIO, glog, GLogFunc, HasGLogFunc(..))

import           Control.Arrow hiding ((+:+))
import           Control.Monad.Bayes.Weighted
import           Control.Monad.State hiding (state)
import           Control.Monad.Trans.Class
import           Data.Foldable
import           Data.HashMap as HM hiding (null,map,mapMaybe)
import           Data.List (maximumBy)
import           Data.Ord (comparing)
import           Data.Utils
import qualified Data.Vector as V
import           GHC.TypeLits
import           Numeric.Probability.Distribution hiding (map, lift)
import           System.Random.MWC.CondensedTable
import           System.Random
import           System.Random.Stateful

import           Engine.OpenGames hiding (lift)
import           Engine.OpticClass
import           Engine.TLL
import           Engine.Diagnostics

--------------------------------------------------------------------------------
-- Messaging

type Rdr action = GLogFunc (Msg action)

data Msg action = AsPlayer String (PlayerMsg action) | UStart | UEnd | WithinU (Msg action) | CalledK (Msg action) | VChooseAction action
  deriving Show

data PlayerMsg action = Outputting | SamplePayoffs (SamplePayoffsMsg action) | AverageUtility (AverageUtilityMsg action)
  deriving Show

data SamplePayoffsMsg action = SampleAction action | SampleRootMsg Int (Msg action) | SampleAverageIs Double
  deriving Show

data AverageUtilityMsg action = StartingAverageUtil | AverageRootMsg (Msg action) | AverageActionChosen action | AverageIterAction Int action | AverageComplete Double
  deriving Show

--------------------------------------------------------------------------------


-- TODO implement the sampler
-- TODO implement printout

type IOOpenGame msg a b x s y r = OpenGame (MonadOptic msg) (MonadContext msg) a b x s y r

type Agent = String



data DiagnosticInfoIO y = DiagnosticInfoIO
  { playerIO          :: String
  , optimalMoveIO     :: y
  , optimalPayoffIO   :: Double
  , currentMoveIO     :: y
  , currentPayoffIO   :: Double}

showDiagnosticInfoInteractive :: (Show y, Ord y) => DiagnosticInfoIO y -> String
showDiagnosticInfoInteractive info =
     "\n"    ++ "Player: " ++ playerIO info
     ++ "\n" ++ "Optimal Move: " ++ (show $ optimalMoveIO info)
     ++ "\n" ++ "Optimal Payoff: " ++ (show $ optimalPayoffIO info)
     ++ "\n" ++ "Current Move: " ++ (show $ currentMoveIO info)
     ++ "\n" ++ "Current Payoff: " ++ (show $ currentPayoffIO info)



-- output string information for a subgame expressions containing information from several players - bayesian
showDiagnosticInfoLIO :: (Show y, Ord y)  => [DiagnosticInfoIO y] -> String
showDiagnosticInfoLIO [] = "\n --No more information--"
showDiagnosticInfoLIO (x:xs)  = showDiagnosticInfoInteractive x ++ "\n --other game-- " ++ showDiagnosticInfoLIO xs


data PrintOutput = PrintOutput

instance (Show y, Ord y) => Apply PrintOutput [DiagnosticInfoIO y] String where
  apply _ x = showDiagnosticInfoLIO x


data Concat = Concat

instance Apply Concat String (String -> String) where
  apply _ x = \y -> x ++ "\n NEWGAME: \n" ++ y


---------------------
-- main functionality

-- all information for all players
generateOutputIO :: forall xs.
               ( MapL   PrintOutput xs     (ConstMap String xs)
               , FoldrL Concat String (ConstMap String xs)
               ) => List xs -> IO ()
generateOutputIO hlist = putStrLn $
  "----Analytics begin----" ++ (foldrL Concat "" $ mapL @_ @_ @(ConstMap String xs) PrintOutput hlist) ++ "----Analytics end----\n"





deviationsInContext :: (Show a, Ord a)
                    =>  Agent -> a -> (a -> IO Double) -> [a] -> IO [DiagnosticInfoIO a]
deviationsInContext name strategy u ys = do
     ls              <- mapM u ys
     strategicPayoff <- u strategy
     let zippedLs    =  zip ys ls
         (optimalPlay, optimalPayoff) = maximumBy (comparing snd) zippedLs
     pure [ DiagnosticInfoIO
            {  playerIO = name
            , optimalMoveIO = optimalPlay
            , optimalPayoffIO = optimalPayoff
            , currentMoveIO   = strategy
            , currentPayoffIO = strategicPayoff
            }]


-- NOTE This ignores the state
dependentDecisionIO_ :: (Eq x, Show x, Ord y, Show y) => String -> Int -> [y] ->  IOOpenGame msg '[Kleisli CondensedTableV x y] '[RIO (GLogFunc msg) (Double,[Double])] x () y Double
          -- s t  a b
-- ^ (average utility of current strategy, [average utility of all possible alternative actions])
dependentDecisionIO_ name sampleSize ys = OpenGame {
  -- ^ ys is the list of possible actions
  play = \(strat ::- Nil) -> let v x = do
                                   g <- newStdGen
                                   gS <- newIOGenM g
                                   action <- genFromTable (runKleisli strat x) gS
                                   return ((),action)
                                 u () r = modify (adjustOrAdd (+ r) r name)
                             in MonadOptic v u,
  evaluate = \(strat ::- Nil) (MonadContext h k) -> do
       let action = do
              (_,x) <- h
              g <- newStdGen
              gS <- newIOGenM g
              genFromTable (runKleisli strat x) gS
           u y     = do
              (z,_) <- h
              evalStateT (do
                             r <- k z y
                           -- ^ utility <- payoff function given other players strategies and my own action y
                             gets ((+ r) . HM.findWithDefault 0.0 name))
                          HM.empty
           -- Sample the average utility from current strategy
           averageUtilStrategy = do
             actionLS' <- replicateM sampleSize action
             utilLS  <- mapM u actionLS'
             return (sum utilLS / fromIntegral sampleSize)
           -- Sample the average utility from a single action
           sampleY sampleSize y = do
                  ls1 <- replicateM sampleSize (u y)
                  pure  (sum ls1 / fromIntegral sampleSize)
           -- Sample the average utility from all actions
           samplePayoffs sampleSize = mapM (sampleY sampleSize) ys
           output = do
             samplePayoffs' <- samplePayoffs sampleSize
             averageUtilStrategy' <- averageUtilStrategy
             return $ (averageUtilStrategy', samplePayoffs')
              in (output ::- Nil) }

data Diagnostics x y = Diagnostics {
  playerName :: String
  , averageUtilStrategy :: Double
  , samplePayoffs :: [Double]
  , currentMove :: x
  , optimalMove :: y
  , optimalPayoff :: Double
  }
  deriving (Show)

dependentDecisionIO
  :: forall x action. (Show x) => String
  -> Int
  -> [action]
  -> IOOpenGame (Msg action) '[Kleisli CondensedTableV x action] '[(RIO (Rdr action)) (Diagnostics x action)] x () action Double
dependentDecisionIO name sampleSize ys = OpenGame { play, evaluate} where

  play :: List '[Kleisli CondensedTableV x action]
       -> MonadOptic (Msg action) x () action Double
  play (strat ::- Nil) =
    MonadOptic v u

    where
      v x = do
        g <- newStdGen
        gS <- newIOGenM g
        action <- genFromTable (runKleisli strat x) gS
        glog (VChooseAction action)
        return ((),action)

      u () r = modify (adjustOrAdd (+ r) r name)

  evaluate :: List '[Kleisli CondensedTableV x action]
           -> MonadContext (Msg action) x () action Double
           -> List '[(RIO (Rdr action)) (Diagnostics x action)]
  evaluate (strat ::- Nil) (MonadContext h k) =
    output ::- Nil

    where

      output =
        RIO.mapRIO (contramap (AsPlayer name)) $ do
        glog Outputting
        zippedLs <- RIO.mapRIO (contramap SamplePayoffs) samplePayoffs
        let samplePayoffs' = map snd zippedLs
        let (optimalPlay, optimalPayoff0) = maximumBy (comparing snd) zippedLs
        (currentMove, averageUtilStrategy') <- RIO.mapRIO (contramap AverageUtility) averageUtilStrategy
        return  Diagnostics{
            playerName = name
          , averageUtilStrategy = averageUtilStrategy'
          , samplePayoffs = samplePayoffs'
          , currentMove = currentMove
          , optimalMove = optimalPlay
          , optimalPayoff = optimalPayoff0
          }

        where
          -- Sample the average utility from all actions
          samplePayoffs = do vs <- mapM sampleY ys
                             pure vs
            where
              -- Sample the average utility from a single action
               sampleY :: action -> RIO (GLogFunc (SamplePayoffsMsg action)) (action, Double)
               sampleY y = do
                  glog (SampleAction y)
                  ls1 <- mapM (\i -> do v <- RIO.mapRIO (contramap (SampleRootMsg i)) $ u y
                                        pure v) [1..sampleSize]
                  let average =  (sum ls1 / fromIntegral sampleSize)
                  glog (SampleAverageIs average)
                  pure (y, average)

          -- Sample the average utility from current strategy
          averageUtilStrategy = do
            glog StartingAverageUtil
            (_,x) <- RIO.mapRIO (contramap AverageRootMsg) h
            g <- newStdGen
            gS <- newIOGenM g
            actionLS' <- mapM (\i -> do
                                        v <- RIO.mapRIO (contramap AverageRootMsg) $ action x gS
                                        glog (AverageActionChosen v)
                                        pure v)
                             [1.. sampleSize]
            utilLS  <- mapM (\(i,a) ->
                                   do glog (AverageIterAction i a)
                                      v <- RIO.mapRIO (contramap AverageRootMsg) $ u a
                                      pure v
                             )
                        (zip [1 :: Int ..] actionLS')
            let average = (sum utilLS / fromIntegral sampleSize)
            glog (AverageComplete average)
            return (x, average)

            where action x gS = do
                    genFromTable (runKleisli strat x) gS

          u y = do
             glog UStart
             (z,_) <- RIO.mapRIO (contramap WithinU) h
             v <-
              RIO.mapRIO (contramap CalledK) $
              evalStateT (do r <-  k z y
                             mp <- gets id
                             gets ((+ r) . HM.findWithDefault 0.0 name))
                          HM.empty
             glog UEnd
             pure v

-- Support functionality for constructing open games
fromLens :: (x -> y) -> (x -> r -> s) -> IOOpenGame msg '[] '[] x s y r
fromLens v u = OpenGame {
  play = \Nil -> MonadOptic (\x -> return (x, v x)) (\x r -> return (u x r)),
  evaluate = \Nil _ -> Nil}


fromFunctions :: (x -> y) -> (r -> s) -> IOOpenGame msg '[] '[] x s y r
fromFunctions f g = fromLens f (const g)



-- discount Operation for repeated structures
discount :: String -> (Double -> Double) -> IOOpenGame msg '[] '[] () () () ()
discount name f = OpenGame {
  play = \_ -> let v () = return ((), ())
                   u () () = modify (adjustOrAdd f (f 0) name)
                 in MonadOptic v u,
  evaluate = \_ _ -> Nil}

--------------------------------------------------------------------------------
-- Logging

logFuncSilent :: CallStack -> Msg action -> IO ()
logFuncSilent _ _ = pure ()

-- ignore this one
logFuncTracing :: Show action => CallStack -> Msg action -> IO ()
logFuncTracing _ (AsPlayer _ (SamplePayoffs (SampleRootMsg _ (CalledK {})))) = pure ()
logFuncTracing _ (AsPlayer _ (AverageUtility (AverageRootMsg (CalledK {})))) = pure ()
logFuncTracing callStack msg = do
  case getCallStack callStack of
     [("glog", srcloc)] -> do
       -- This is slow - consider moving it elsewhere if speed becomes a problem.
       fp <- makeRelativeToCurrentDirectory (srcLocFile srcloc)
       S8.putStrLn (S8.pack (prettySrcLoc0 (srcloc{srcLocFile=fp}) ++ show msg))
     _ -> error "Huh?"

prettySrcLoc0 :: SrcLoc -> String
prettySrcLoc0 SrcLoc {..}
  = foldr (++) ""
      [ srcLocFile, ":"
      , show srcLocStartLine, ":"
      , show srcLocStartCol, ": "
      ]

data Readr = Readr { indentRef :: IORef Int }
logFuncStructured indentRef _ msg = flip runReaderT Readr{indentRef} (go msg)

  where

   go = \case
     AsPlayer player msg -> do
       case msg of
         Outputting -> pure ()
         SamplePayoffs pmsg ->
           case pmsg of
             SampleAction action -> logln ("SampleY: " ++ take 1 (show action))
             SampleRootMsg i msg -> do
               case msg of
                 UStart -> logstr "u["
                 CalledK msg -> case msg of
                   VChooseAction action -> logstr (take 1 (show action))
                   _ -> pure ()
                 UEnd -> do logstr "]"; newline
                 _ -> pure ()
             _ -> pure ()
         _ -> pure ()
     _ -> pure ()

   logln :: String -> (ReaderT Readr IO) ()
   logln s = do newline; logstr s; newline

   logstr :: String -> (ReaderT Readr IO) ()
   logstr s = liftIO $ S8.putStr (S8.pack s)

   newline  :: ReaderT Readr IO ()
   newline =
      do Readr{indentRef} <- ask
         liftIO $
          do i <- readIORef indentRef
             S8.putStr ("\n" <> S8.replicate i ' ')


   indent :: ReaderT Readr IO ()
   indent = (do Readr{indentRef} <- ask; liftIO $ modifyIORef' indentRef (+4))

   deindent :: ReaderT Readr IO ()
   deindent =  (do Readr{indentRef} <- ask; liftIO $ modifyIORef' indentRef (subtract 4))
