{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE DefaultSignatures     #-}

module Engine.OpticClass where
--   ( Optic(..)
--   , Choice(..)
--   , Precontext(..)
--   , Context(..)
--   , ContextAdd(..)
--   , identity
--   ) where


import           Control.Monad.State                hiding (state)
-- import           Numeric.Probability.Distribution   hiding (lift)
import           Data.Maybe
import Data.Kind (Type)
import Data.Singletons
import Data.Singletons.TH

$(singletons [d|
    data Choice a b = Choice1 a | Choice2 b

    pick :: (a -> c) -> (b -> c) -> Choice a b -> c
    pick f _ (Choice1 a) = f a
    pick _ g (Choice2 b) = g b

    data Option a = Some a | None

    extract :: b -> (a -> b) -> Option a -> b
    extract def f (Some a) = f a
    extract def f None = def
    |])

class Optic o where
  lens :: (s -> a) -> (s -> b -> t) -> o s t a b
  (>>>>) :: o s t a b -> o a b p q -> o s t p q
  (&&&&) :: o s1 t1 a1 b1 -> o s2 t2 a2 b2 -> o (s1, s2) (t1, t2) (a1, a2) (b1, b2)
  (++++) :: o s1 t a1 b -> o s2 t a2 b -> o (Choice s1 s2) t (Choice a1 a2) b

identity :: (Optic o) => o s t s t
identity = lens id (flip const)

class Precontext c where
  void :: c () () () ()

-- Precontext is a separate class to Context because otherwise the typechecker throws a wobbly

class (Optic o, Precontext c) => Context c o where
  cmap :: o s1 t1 s2 t2 -> o a1 b1 a2 b2 -> c s1 t1 a2 b2 -> c s2 t2 a1 b1
  (//) :: (Show s1, Show s2) => o s1 t1 a1 b1 -> c (s1, s2) (t1, t2) (a1, a2) (b1, b2) -> c s2 t2 a2 b2
  (\\) :: (Show s1, Show s2) => o s2 t2 a2 b2 -> c (s1, s2) (t1, t2) (a1, a2) (b1, b2) -> c s1 t1 a1 b1

$(singletons [d|
  class ContextAdd c where
    prl :: c (Choice s1 s2) t (Choice a1 a2) b -> Option (c s1 t a1 b)
    prr :: c (Choice s1 s2) t (Choice a1 a2) b -> Option (c s2 t a2 b)
    match :: c (Choice s1 s2) t (Choice a1 a2) b -> Choice (c s1 t a1 b) (c s2 t a2 b)|])

$(promote [d|
  choiceTy :: forall c x1 s y1 r x2 y2.
              ContextAdd c => (c x1 s y1 r -> [Type])
                           -> (c x2 s y2 r -> [Type])
                           -> c (Choice x1 x2) s (Choice y1 y2) r -> [Type]
  choiceTy f g ctx = pick f g (match ctx)|])

{-
-------------------------------------------------------------
--- replicate the old implementation of a stochastic context
type Stochastic = T Double
type Vector = String -> Double

data StochasticStatefulOptic s t a b where
  StochasticStatefulOptic :: (s -> Stochastic (z, a))
                          -> (z -> b -> StateT Vector Stochastic t)
                          -> StochasticStatefulOptic s t a b

instance Optic StochasticStatefulOptic where
  lens v u = StochasticStatefulOptic (\s -> return (s, v s)) (\s b -> return (u s b))
  (>>>>) (StochasticStatefulOptic v1 u1) (StochasticStatefulOptic v2 u2) = StochasticStatefulOptic v u
    where v s = do {(z1, a) <- v1 s; (z2, p) <- v2 a; return ((z1, z2), p)}
          u (z1, z2) q = do {b <- u2 z2 q; u1 z1 b}
  (&&&&) (StochasticStatefulOptic v1 u1) (StochasticStatefulOptic v2 u2) = StochasticStatefulOptic v u
    where v (s1, s2) = do {(z1, a1) <- v1 s1; (z2, a2) <- v2 s2; return ((z1, z2), (a1, a2))}
          u (z1, z2) (b1, b2) = do {t1 <- u1 z1 b1; t2 <- u2 z2 b2; return (t1, t2)}
  (++++) (StochasticStatefulOptic v1 u1) (StochasticStatefulOptic v2 u2) = StochasticStatefulOptic v u
    where v (Left s1)  = do {(z1, a1) <- v1 s1; return (Left z1, Left a1)}
          v (Right s2) = do {(z2, a2) <- v2 s2; return (Right z2, Right a2)}
          u (Left z1) b  = u1 z1 b
          u (Right z2) b = u2 z2 b

data StochasticStatefulContext s t a b where
  StochasticStatefulContext :: Show z => Stochastic (z, s) -> (z -> a -> StateT Vector Stochastic b) -> StochasticStatefulContext s t a b

instance Precontext StochasticStatefulContext where
  void = StochasticStatefulContext (return ((), ())) (\() () -> return ())

instance Context StochasticStatefulContext StochasticStatefulOptic where
  cmap (StochasticStatefulOptic v1 u1) (StochasticStatefulOptic v2 u2) (StochasticStatefulContext h k)
            = let h' = do {(z, s) <- h; (_, s') <- v1 s; return (z, s')}
                  k' z a = do {(z', a') <- lift (v2 a); b' <- k z a'; u2 z' b'}
               in StochasticStatefulContext h' k'
  (//) (StochasticStatefulOptic v u) (StochasticStatefulContext h k)
            = let h' = do {(z, (s1, s2)) <- h; return ((z, s1), s2)}
                  k' (z, s1) a2 = do {(_, a1) <- lift (v s1); (_, b2) <- k z (a1, a2); return b2}
               in StochasticStatefulContext h' k'
  (\\) (StochasticStatefulOptic v u) (StochasticStatefulContext h k)
            = let h' = do {(z, (s1, s2)) <- h; return ((z, s2), s1)}
                  k' (z, s2) a1 = do {(_, a2) <- lift (v s2); (b1, _) <- k z (a1, a2); return b1}
               in StochasticStatefulContext h' k'

instance ContextAdd StochasticStatefulContext where
  prl (StochasticStatefulContext h k)
    = let fs = [((z, s1), p) | ((z, Left s1), p) <- decons h]
       in if null fs then Nothing
                     else Just (StochasticStatefulContext (fromFreqs fs) (\z a1 -> k z (Left a1)))
  prr (StochasticStatefulContext h k)
    = let fs = [((z, s2), p) | ((z, Right s2), p) <- decons h]
       in if null fs then Nothing
                     else Just (StochasticStatefulContext (fromFreqs fs) (\z a2 -> k z (Right a2)))

-}
