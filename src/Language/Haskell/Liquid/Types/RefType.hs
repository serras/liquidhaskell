{-# LANGUAGE IncoherentInstances       #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# LANGUAGE TypeSynonymInstances      #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE PatternGuards             #-}
{-# LANGUAGE ImplicitParams            #-}
{-# LANGUAGE ConstraintKinds           #-}

-- | Refinement Types. Mostly mirroring the GHC Type definition, but with
--   room for refinements of various sorts.
-- TODO: Desperately needs re-organization.

module Language.Haskell.Liquid.Types.RefType (

  -- * Functions for lifting Reft-values to Spec-values
    uTop, uReft, uRType, uRType', uRTypeGen, uPVar

  -- * Applying a solution to a SpecType
  , applySolution

  -- * Functions for decreasing arguments
  , isDecreasing, makeDecrType, makeNumEnv
  , makeLexRefa

  -- * Functions for manipulating `Predicate`s
  , pdVar
  , findPVar
  , FreeVar, freeTyVars, tyClasses, tyConName

  -- * Quantifying RTypes
  , quantifyRTy
  , quantifyFreeRTy

  -- * RType constructors
  , ofType, toType, bareOfType
  , bTyVar, rTyVar, rVar, rApp, gApp, rEx
  , symbolRTyVar, bareRTyVar
  , tyConBTyCon
  , pdVarReft

  -- * Substitutions
  , subts, subvPredicate, subvUReft
  , subsTyVar_meet, subsTyVar_meet', subsTyVar_nomeet
  , subsTyVars_nomeet, subsTyVars_meet

  -- * Destructors
  , addTyConInfo
  , appRTyCon
  , typeUniqueSymbol
  , classBinds
  , isSizeable


  -- * Manipulating Refinements in RTypes
  , strengthen
  , generalize
  , normalizePds
  , dataConMsReft
  , dataConReft
  , rTypeSortedReft
  , rTypeSort
  , typeSort
  , shiftVV

  -- * TODO: classify these
  -- , mkDataConIdsTy
  , expandProductType
  , mkTyConInfo
  , strengthenRefTypeGen
  , strengthenDataConType
  , isBaseTy
  , updateRTVar, isValKind, kindToRType
  , rTVarInfo

  ) where

-- import           GHC.Stack
import TyCoRep
import Prelude hiding (error)
import WwLib
import FamInstEnv (emptyFamInstEnv)
import Name             hiding (varName)
import Var
import GHC              hiding (Located)
import DataCon
import qualified TyCon  as TC
import Type             (splitFunTys, expandTypeSynonyms, substTyWith, isClassPred, isEqPred, isNomEqPred)
import TysWiredIn       (listTyCon, intDataCon, trueDataCon, falseDataCon,
                         intTyCon, charTyCon, typeNatKind, typeSymbolKind, stringTy, intTy)
-- import TysPrim          (eqPrimTyCon)
-- import           Data.Monoid      hiding ((<>))
import           Data.Maybe               (fromMaybe, isJust, fromJust)
import           Data.Hashable
import qualified Data.HashMap.Strict  as M
import qualified Data.HashSet         as S
import qualified Data.List as L

import Control.Monad  (void)
import Text.Printf
import Text.PrettyPrint.HughesPJ

import Language.Haskell.Liquid.Types.Errors
import Language.Haskell.Liquid.Types.PrettyPrint
import qualified Language.Fixpoint.Types as F
import Language.Fixpoint.Types hiding (DataDecl (..), DataCtor (..), panic, shiftVV, Predicate, isNumeric)
import Language.Fixpoint.Types.Visitor (mapKVars, Visitable)
import Language.Haskell.Liquid.Types hiding (R, DataConP (..))

import Language.Haskell.Liquid.Types.Variance

import Language.Haskell.Liquid.Misc
import Language.Haskell.Liquid.Types.Names
import Language.Fixpoint.Misc
import qualified Language.Haskell.Liquid.GHC.Misc as GM
import Language.Haskell.Liquid.GHC.Play (mapType, stringClassArg) -- , dataConImplicitIds)

import Data.List (sort, foldl')

strengthenDataConType :: (Var, SpecType) -> (Var, SpecType)
strengthenDataConType (x, t) = (x, fromRTypeRep trep {ty_res = tres})
  where
    tres     = F.notracepp _msg $ ty_res trep `strengthen` MkUReft (exprReft expr) mempty mempty
    trep     = toRTypeRep t
    _msg     = "STRENGTHEN-DATACONTYPE x = " ++ F.showpp (x, (zip xs ts))
    (xs, ts) = dataConArgs trep
    as       = ty_vars  trep
    x'       = symbol x
    expr | null xs && null as = EVar x'
         | otherwise          = mkEApp (dummyLoc x') (EVar <$> xs)


dataConArgs :: SpecRep -> ([Symbol], [SpecType])
dataConArgs trep = unzip [ (x, t) | (x, t) <- zip xs ts, isValTy t]
  where
    xs           = ty_binds trep
    -- xs           = zipWith (\_ i -> (symbol ("x" ++ show i))) (ty_args trep) [1..]
    ts           = ty_args trep
    isValTy      = not . GM.isPredType . toType

-- RJ: AAAAAAARGHHH: this is duplicate of RT.strengthenDataConType
{-
makeDataConCtor :: Var -> SpecType
makeDataConCtor x = (dummyLoc . fromRTypeRep $ trep {ty_res = res, ty_binds = xs})
  where
    tres     = F.tracepp _msg $ ty_res trep `strengthen` MkUReft (exprReft expr) mempty mempty
    trep     = toRTypeRep . ofType . varType $ x
    _msg     = "STRENGTHEN-DATACONTYPE x = " ++ F.showpp (x, (zip xs ts))
    (xs, ts) = dataConArgs trep
    as       = ty_vars  trep
    x'       = symbol x
    expr | null xs && null as = EVar x'
         | otherwise          = mkEApp (dummyLoc x') (EVar <$> xs)

makeDataConCtor :: Var -> (Var, LocSpecType)
makeDataConCtor x = (x, dummyLoc . fromRTypeRep $ trep {ty_res = res, ty_binds = xs})
  where
    t    :: SpecType
    t    = ofType $ varType x
    trep = toRTypeRep t
    xs   = zipWith (\_ i -> (symbol ("x" ++ show i))) (ty_args trep) [1..]

    res  = ty_res trep `strengthen` MkUReft ref mempty mempty
    vv   = vv_
    x'   = symbol x
    ref  = Reft (vv, PAtom Eq (EVar vv) eq)
    eq   | null (ty_vars trep) && null xs = EVar x'
         | otherwise = mkEApp (dummyLoc x') (EVar <$> xs)
-}

pdVar :: PVar t -> Predicate
pdVar v        = Pr [uPVar v]

findPVar :: [PVar (RType c tv ())] -> UsedPVar -> PVar (RType c tv ())
findPVar ps p = PV name ty v (zipWith (\(_, _, e) (t, s, _) -> (t, s, e)) (pargs p) args)
  where
    PV name ty v args = fromMaybe (msg p) $ L.find ((== pname p) . pname) ps
    msg p = panic Nothing $ "RefType.findPVar" ++ showpp p ++ "not found"

-- | Various functions for converting vanilla `Reft` to `Spec`

uRType          ::  RType c tv a -> RType c tv (UReft a)
uRType          = fmap uTop

uRType'         ::  RType c tv (UReft a) -> RType c tv a
uRType'         = fmap ur_reft

uRTypeGen       :: Reftable b => RType c tv a -> RType c tv b
uRTypeGen       = fmap $ const mempty

uPVar           :: PVar t -> UsedPVar
uPVar           = void

uReft           :: (Symbol, Expr) -> UReft Reft
uReft           = uTop . Reft

uTop            ::  r -> UReft r
uTop r          = MkUReft r mempty mempty

--------------------------------------------------------------------
-------------- (Class) Predicates for Valid Refinement Types -------
--------------------------------------------------------------------


-- Monoid Instances ---------------------------------------------------------


instance ( SubsTy tv (RType c tv ()) (RType c tv ())
         , SubsTy tv (RType c tv ()) c
         , OkRT c tv r
         , FreeVar c tv
         , SubsTy tv (RType c tv ()) r
         , SubsTy tv (RType c tv ()) tv
         , SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ()))
         )
        => Monoid (RType c tv r)  where
  mempty  = panic Nothing "mempty: RType"
  mappend = strengthenRefType

-- MOVE TO TYPES
instance ( SubsTy tv (RType c tv ()) c
         , OkRT c tv r
         , FreeVar c tv
         , SubsTy tv (RType c tv ()) r
         , SubsTy tv (RType c tv ()) (RType c tv ())
         , SubsTy tv (RType c tv ()) tv
         , SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ()))
         )
         => Monoid (RTProp c tv r) where
  mempty         = panic Nothing "mempty: RTProp"

  mappend (RProp s1 (RHole r1)) (RProp s2 (RHole r2))
    | isTauto r1 = RProp s2 (RHole r2)
    | isTauto r2 = RProp s1 (RHole r1)
    | otherwise  = RProp s1 $ RHole $ r1 `meet`
                               (subst (mkSubst $ zip (fst <$> s2) (EVar . fst <$> s1)) r2)

  mappend (RProp s1 t1) (RProp s2 t2)
    | isTrivial t1 = RProp s2 t2
    | isTrivial t2 = RProp s1 t1
    | otherwise    = RProp s1 $ t1  `strengthenRefType`
                                (subst (mkSubst $ zip (fst <$> s2) (EVar . fst <$> s1)) t2)

{-
NV: The following makes ghc diverge thus dublicating the code
instance ( OkRT c tv r
         , FreeVar c tv
         , SubsTy tv (RType c tv ()) r
         , SubsTy tv (RType c tv ()) (RType c tv ())
         , SubsTy tv (RType c tv ()) c
         , SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ()))
         , SubsTy tv (RType c tv ()) tv
         ) => Reftable (RTProp c tv r) where
  isTauto (RProp _ (RHole r)) = isTauto r
  isTauto (RProp _ t)         = isTrivial t
  top (RProp _ (RHole _))     = panic Nothing "RefType: Reftable top called on (RProp _ (RHole _))"
  top (RProp xs t)            = RProp xs $ mapReft top t
  ppTy (RProp _ (RHole r)) d  = ppTy r d
  ppTy (RProp _ _) _          = panic Nothing "RefType: Reftable ppTy in RProp"
  toReft                      = panic Nothing "RefType: Reftable toReft"
  params                      = panic Nothing "RefType: Reftable params for Ref"
  bot                         = panic Nothing "RefType: Reftable bot    for Ref"
  ofReft                      = panic Nothing "RefType: Reftable ofReft for Ref"
-}

instance Reftable (RTProp RTyCon RTyVar (UReft Reft)) where
  isTauto (RProp _ (RHole r)) = isTauto r
  isTauto (RProp _ t)         = isTrivial t
  top (RProp _ (RHole _))     = panic Nothing "RefType: Reftable top called on (RProp _ (RHole _))"
  top (RProp xs t)            = RProp xs $ mapReft top t
  ppTy (RProp _ (RHole r)) d  = ppTy r d
  ppTy (RProp _ _) _          = panic Nothing "RefType: Reftable ppTy in RProp"
  toReft                      = panic Nothing "RefType: Reftable toReft"
  params                      = panic Nothing "RefType: Reftable params for Ref"
  bot                         = panic Nothing "RefType: Reftable bot    for Ref"
  ofReft                      = panic Nothing "RefType: Reftable ofReft for Ref"

instance Reftable (RTProp RTyCon RTyVar ()) where
  isTauto (RProp _ (RHole r)) = isTauto r
  isTauto (RProp _ t)         = isTrivial t
  top (RProp _ (RHole _))     = panic Nothing "RefType: Reftable top called on (RProp _ (RHole _))"
  top (RProp xs t)            = RProp xs $ mapReft top t
  ppTy (RProp _ (RHole r)) d  = ppTy r d
  ppTy (RProp _ _) _          = panic Nothing "RefType: Reftable ppTy in RProp"
  toReft                      = panic Nothing "RefType: Reftable toReft"
  params                      = panic Nothing "RefType: Reftable params for Ref"
  bot                         = panic Nothing "RefType: Reftable bot    for Ref"
  ofReft                      = panic Nothing "RefType: Reftable ofReft for Ref"

instance Reftable (RTProp BTyCon BTyVar (UReft Reft)) where
  isTauto (RProp _ (RHole r)) = isTauto r
  isTauto (RProp _ t)         = isTrivial t
  top (RProp _ (RHole _))     = panic Nothing "RefType: Reftable top called on (RProp _ (RHole _))"
  top (RProp xs t)            = RProp xs $ mapReft top t
  ppTy (RProp _ (RHole r)) d  = ppTy r d
  ppTy (RProp _ _) _          = panic Nothing "RefType: Reftable ppTy in RProp"
  toReft                      = panic Nothing "RefType: Reftable toReft"
  params                      = panic Nothing "RefType: Reftable params for Ref"
  bot                         = panic Nothing "RefType: Reftable bot    for Ref"
  ofReft                      = panic Nothing "RefType: Reftable ofReft for Ref"

instance Reftable (RTProp BTyCon BTyVar ())  where
  isTauto (RProp _ (RHole r)) = isTauto r
  isTauto (RProp _ t)         = isTrivial t
  top (RProp _ (RHole _))     = panic Nothing "RefType: Reftable top called on (RProp _ (RHole _))"
  top (RProp xs t)            = RProp xs $ mapReft top t
  ppTy (RProp _ (RHole r)) d  = ppTy r d
  ppTy (RProp _ _) _          = panic Nothing "RefType: Reftable ppTy in RProp"
  toReft                      = panic Nothing "RefType: Reftable toReft"
  params                      = panic Nothing "RefType: Reftable params for Ref"
  bot                         = panic Nothing "RefType: Reftable bot    for Ref"
  ofReft                      = panic Nothing "RefType: Reftable ofReft for Ref"

instance Reftable (RTProp RTyCon RTyVar Reft) where
  isTauto (RProp _ (RHole r)) = isTauto r
  isTauto (RProp _ t)         = isTrivial t
  top (RProp _ (RHole _))     = panic Nothing "RefType: Reftable top called on (RProp _ (RHole _))"
  top (RProp xs t)            = RProp xs $ mapReft top t
  ppTy (RProp _ (RHole r)) d  = ppTy r d
  ppTy (RProp _ _) _          = panic Nothing "RefType: Reftable ppTy in RProp"
  toReft                      = panic Nothing "RefType: Reftable toReft"
  params                      = panic Nothing "RefType: Reftable params for Ref"
  bot                         = panic Nothing "RefType: Reftable bot    for Ref"
  ofReft                      = panic Nothing "RefType: Reftable ofReft for Ref"

----------------------------------------------------------------------------
-- | Subable Instances -----------------------------------------------------
----------------------------------------------------------------------------

instance Subable (RRProp Reft) where
  syms (RProp ss (RHole r)) = (fst <$> ss) ++ syms r
  syms (RProp ss t)      = (fst <$> ss) ++ syms t


  subst su (RProp ss (RHole r)) = RProp (mapSnd (subst su) <$> ss) $ RHole $ subst su r
  subst su (RProp ss r)  = RProp  (mapSnd (subst su) <$> ss) $ subst su r


  substf f (RProp ss (RHole r)) = RProp (mapSnd (substf f) <$> ss) $ RHole $ substf f r
  substf f (RProp ss r) = RProp  (mapSnd (substf f) <$> ss) $ substf f r

  substa f (RProp ss (RHole r)) = RProp (mapSnd (substa f) <$> ss) $ RHole $ substa f r
  substa f (RProp ss r) = RProp  (mapSnd (substa f) <$> ss) $ substa f r


-------------------------------------------------------------------------------
-- | Reftable Instances -------------------------------------------------------
-------------------------------------------------------------------------------

instance (PPrint r, Reftable r, SubsTy RTyVar (RType RTyCon RTyVar ()) r, Reftable (RTProp RTyCon RTyVar r))
    => Reftable (RType RTyCon RTyVar r) where
  isTauto     = isTrivial
  ppTy        = panic Nothing "ppTy RProp Reftable"
  toReft      = panic Nothing "toReft on RType"
  params      = panic Nothing "params on RType"
  bot         = panic Nothing "bot on RType"
  ofReft      = panic Nothing "ofReft on RType"


instance Reftable (RType BTyCon BTyVar (UReft Reft)) where
  isTauto     = isTrivial
  top t       = mapReft top t
  ppTy        = panic Nothing "ppTy RProp Reftable"
  toReft      = panic Nothing "toReft on RType"
  params      = panic Nothing "params on RType"
  bot         = panic Nothing "bot on RType"
  ofReft      = panic Nothing "ofReft on RType"



-- MOVE TO TYPES
instance Fixpoint String where
  toFix = text

-- MOVE TO TYPES
instance Fixpoint Class where
  toFix = text . GM.showPpr

-- MOVE TO TYPES
class FreeVar a v where
  freeVars :: a -> [v]

-- MOVE TO TYPES
instance FreeVar RTyCon RTyVar where
  freeVars = (RTV <$>) . GM.tyConTyVarsDef . rtc_tc

-- MOVE TO TYPES
instance FreeVar BTyCon BTyVar where
  freeVars _ = []

-- Eq Instances ------------------------------------------------------

-- MOVE TO TYPES
instance (Eq c, Eq tv, Hashable tv) => Eq (RType c tv ()) where
  (==) = eqRSort M.empty

eqRSort :: (Eq a, Eq k, Hashable k)
        => M.HashMap k k -> RType a k t -> RType a k t1 -> Bool
eqRSort m (RAllP _ t) (RAllP _ t')
  = eqRSort m t t'
eqRSort m (RAllS _ t) (RAllS _ t')
  = eqRSort m t t'
eqRSort m (RAllP _ t) t'
  = eqRSort m t t'
eqRSort m (RAllT a t) (RAllT a' t')
  | a == a'
  = eqRSort m t t'
  | otherwise
  = eqRSort (M.insert (ty_var_value a') (ty_var_value a) m) t t'
eqRSort m (RAllT _ t) t'
  = eqRSort m t t'
eqRSort m t (RAllT _ t')
  = eqRSort m t t'
eqRSort m (RFun _ t1 t2 _) (RFun _ t1' t2' _)
  = eqRSort m t1 t1' && eqRSort m t2 t2'
eqRSort m (RAppTy t1 t2 _) (RAppTy t1' t2' _)
  = eqRSort m t1 t1' && eqRSort m t2 t2'
eqRSort m (RApp c ts _ _) (RApp c' ts' _ _)
  = c == c' && length ts == length ts' && and (zipWith (eqRSort m) ts ts')
eqRSort m (RVar a _) (RVar a' _)
  = a == M.lookupDefault a' a' m
eqRSort _ (RHole _) _
  = True
eqRSort _ _         (RHole _)
  = True
eqRSort _ _ _
  = False

--------------------------------------------------------------------------------
-- | Wrappers for GHC Type Elements --------------------------------------------
--------------------------------------------------------------------------------

instance Eq Predicate where
  (==) = eqpd

eqpd :: Predicate -> Predicate -> Bool
eqpd (Pr vs) (Pr ws)
  = and $ (length vs' == length ws') : [v == w | (v, w) <- zip vs' ws']
    where
      vs' = sort vs
      ws' = sort ws


instance Eq RTyVar where
  -- FIXME: need to compare unique and string because we reuse
  -- uniques in stringTyVar and co.
  RTV α == RTV α' = α == α' && getOccName α == getOccName α'

instance Ord RTyVar where
  compare (RTV α) (RTV α') = case compare α α' of
    EQ -> compare (getOccName α) (getOccName α')
    o  -> o

instance Hashable RTyVar where
  hashWithSalt i (RTV α) = hashWithSalt i α

-- TyCon isn't comparable
--instance Ord RTyCon where
--  compare x y = compare (rtc_tc x) (rtc_tc y)

instance Hashable RTyCon where
  hashWithSalt i = hashWithSalt i . rtc_tc

--------------------------------------------------------------------------------
-- | Helper Functions (RJ: Helping to do what?) --------------------------------
--------------------------------------------------------------------------------

rVar :: Monoid r => TyVar -> RType c RTyVar r
rVar   = (`RVar` mempty) . RTV

rTyVar :: TyVar -> RTyVar
rTyVar = RTV

updateRTVar :: Monoid r => RTVar RTyVar i -> RTVar RTyVar (RType RTyCon RTyVar r)
updateRTVar (RTVar (RTV a) _) = RTVar (RTV a) (rTVarInfo a)

rTVar :: Monoid r => TyVar -> RTVar RTyVar (RRType r)
rTVar a = RTVar (RTV a) (rTVarInfo a)

bTVar :: Monoid r => TyVar -> RTVar BTyVar (BRType r)
bTVar a = RTVar (BTV (symbol a)) (bTVarInfo a)

bTVarInfo :: Monoid r => TyVar -> RTVInfo (BRType r)
bTVarInfo = mkTVarInfo kindToBRType

rTVarInfo :: Monoid r => TyVar -> RTVInfo (RRType r)
rTVarInfo = mkTVarInfo kindToRType

mkTVarInfo :: (Kind -> s) -> TyVar -> RTVInfo s
mkTVarInfo k2t a = RTVInfo
  { rtv_name   = symbol    $ varName a
  , rtv_kind   = k2t       $ tyVarKind a
  , rtv_is_val = isValKind $ tyVarKind a
  }

kindToRType :: Monoid r => Type -> RRType r
kindToRType = kindToRType_ ofType

kindToBRType :: Monoid r => Type -> BRType r
kindToBRType = kindToRType_ bareOfType

kindToRType_ :: (Type -> z) -> Type -> z
kindToRType_ ofType        = ofType . go
  where
    go t
     | t == typeSymbolKind = stringTy
     | t == typeNatKind    = intTy
     | otherwise           = t

isValKind :: Kind -> Bool
isValKind x = x == typeNatKind || x == typeSymbolKind

bTyVar :: Symbol -> BTyVar
bTyVar      = BTV

symbolRTyVar :: Symbol -> RTyVar
symbolRTyVar = rTyVar . GM.stringTyVar . symbolString

bareRTyVar :: BTyVar -> RTyVar
bareRTyVar (BTV tv) = symbolRTyVar tv

normalizePds :: (OkRT c tv r) => RType c tv r -> RType c tv r
normalizePds t = addPds ps t'
  where
    (t', ps)   = nlzP [] t

rPred :: PVar (RType c tv ()) -> RType c tv r -> RType c tv r
rPred     = RAllP

rEx :: Foldable t
    => t (Symbol, RType c tv r) -> RType c tv r -> RType c tv r
rEx xts t = foldr (\(x, tx) t -> REx x tx t) t xts

rApp :: TyCon
     -> [RType RTyCon tv r]
     -> [RTProp RTyCon tv r]
     -> r
     -> RType RTyCon tv r
rApp c = RApp (tyConRTyCon c)

gApp :: TyCon -> [RTyVar] -> [PVar a] -> SpecType
gApp tc αs πs = rApp tc
                  [rVar α | RTV α <- αs]
                  (rPropP [] . pdVarReft <$> πs)
                  mempty

pdVarReft :: PVar t -> UReft Reft
pdVarReft = (\p -> MkUReft mempty p mempty) . pdVar

tyConRTyCon :: TyCon -> RTyCon
tyConRTyCon c = RTyCon c [] (mkTyConInfo c [] [] Nothing)

-- bApp :: (Monoid r) => TyCon -> [BRType r] -> BRType r
bApp :: TyCon -> [BRType r] -> [BRProp r] -> r -> BRType r
bApp c = RApp (tyConBTyCon c)

tyConBTyCon :: TyCon -> BTyCon
tyConBTyCon = mkBTyCon . fmap tyConName . GM.locNamedThing
-- tyConBTyCon = mkBTyCon . fmap symbol . locNamedThing

--- NV TODO : remove this code!!!

addPds :: Foldable t
       => t (PVar (RType c tv ())) -> RType c tv r -> RType c tv r
addPds ps (RAllT v t) = RAllT v $ addPds ps t
addPds ps t           = foldl' (flip rPred) t ps

nlzP :: (OkRT c tv r) => [PVar (RType c tv ())] -> RType c tv r -> (RType c tv r, [PVar (RType c tv ())])
nlzP ps t@(RVar _ _ )
 = (t, ps)
nlzP ps (RImpF b t1 t2 r)
 = (RImpF b t1' t2' r, ps ++ ps1 ++ ps2)
  where (t1', ps1) = nlzP [] t1
        (t2', ps2) = nlzP [] t2
nlzP ps (RFun b t1 t2 r)
 = (RFun b t1' t2' r, ps ++ ps1 ++ ps2)
  where (t1', ps1) = nlzP [] t1
        (t2', ps2) = nlzP [] t2
nlzP ps (RAppTy t1 t2 r)
 = (RAppTy t1' t2' r, ps ++ ps1 ++ ps2)
  where (t1', ps1) = nlzP [] t1
        (t2', ps2) = nlzP [] t2
nlzP ps (RAllT v t )
 = (RAllT v t', ps ++ ps')
  where (t', ps') = nlzP [] t
nlzP ps t@(RApp _ _ _ _)
 = (t, ps)
nlzP ps (RAllS _ t)
 = (t, ps)
nlzP ps (RAllP p t)
 = (t', [p] ++ ps ++ ps')
  where (t', ps') = nlzP [] t
nlzP ps t@(REx _ _ _)
 = (t, ps)
nlzP ps t@(RRTy _ _ _ t')
 = (t, ps ++ ps')
 where ps' = snd $ nlzP [] t'
nlzP ps t@(RAllE _ _ _)
 = (t, ps)
nlzP _ t
 = panic Nothing $ "RefType.nlzP: cannot handle " ++ show t

strengthenRefTypeGen, strengthenRefType ::
         (  OkRT c tv r
         , FreeVar c tv
         , SubsTy tv (RType c tv ()) (RType c tv ())
         , SubsTy tv (RType c tv ()) c
         , SubsTy tv (RType c tv ()) r
         , SubsTy tv (RType c tv ()) tv
         , SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ()))
         ) => RType c tv r -> RType c tv r -> RType c tv r

strengthenRefType_ ::
         ( OkRT c tv r
         , FreeVar c tv
         , SubsTy tv (RType c tv ()) (RType c tv ())
         , SubsTy tv (RType c tv ()) c
         , SubsTy tv (RType c tv ()) r
         , SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ()))
         , SubsTy tv (RType c tv ()) tv
         ) => (RType c tv r -> RType c tv r -> RType c tv r)
           ->  RType c tv r -> RType c tv r -> RType c tv r

strengthenRefTypeGen t1 t2 = strengthenRefType_ f t1 t2
  where
    f (RVar v1 r1) t  = RVar v1 (r1 `meet` fromMaybe mempty (stripRTypeBase t))
    f t (RVar v1 r1)  = RVar v1 (r1 `meet` fromMaybe mempty (stripRTypeBase t))
    f t1 t2           = panic Nothing $ printf "strengthenRefTypeGen on differently shaped types \nt1 = %s [shape = %s]\nt2 = %s [shape = %s]"
                         (pprt_raw t1) (showpp (toRSort t1)) (pprt_raw t2) (showpp (toRSort t2))

pprt_raw :: (OkRT c tv r) => RType c tv r -> String
pprt_raw = render . rtypeDoc Full

{- [NOTE:StrengthenRefType] disabling the `meetable` check because

      (1) It requires the 'TCEmb TyCon' to deal with the fact that sometimes,
          GHC uses the "Family Instance" TyCon e.g. 'R:UniquePerson' and sometimes
          the vanilla TyCon App form, e.g. 'Unique Person'
      (2) We could pass in the TCEmb but that would break the 'Monoid' instance for
          RType. The 'Monoid' instance was was probably a bad idea to begin with,
          and we probably ought to do away with it entirely, but thats a battle I'll
          leave for another day.

    Consequently, its up to users of `strengthenRefType` (and associated functions)
    to make sure that the two types are compatible. For an example, see 'meetVarTypes'.
 -}

strengthenRefType t1 t2
  | True -- _meetable t1 t2
  = strengthenRefType_ (\x _ -> x) t1 t2
  | otherwise
  = panic Nothing msg
  where
    msg = printf "strengthen on differently shaped reftypes \nt1 = %s [shape = %s]\nt2 = %s [shape = %s]"
            (showpp t1) (showpp (toRSort t1)) (showpp t2) (showpp (toRSort t2))

_meetable :: (OkRT c tv r) => RType c tv r -> RType c tv r -> Bool
_meetable t1 t2 = toRSort t1 == toRSort t2

strengthenRefType_ f (RAllT a1 t1) (RAllT a2 t2)
  = RAllT a1 $ strengthenRefType_ f t1 (subsTyVar_meet (ty_var_value a2, toRSort t, t) t2)
  where t = RVar (ty_var_value a1) mempty

strengthenRefType_ f (RAllT a t1) t2
  = RAllT a $ strengthenRefType_ f t1 t2

strengthenRefType_ f t1 (RAllT a t2)
  = RAllT a $ strengthenRefType_ f t1 t2

strengthenRefType_ f (RAllP p1 t1) (RAllP _ t2)
  = RAllP p1 $ strengthenRefType_ f t1 t2

strengthenRefType_ f (RAllP p t1) t2
  = RAllP p $ strengthenRefType_ f t1 t2

strengthenRefType_ f t1 (RAllP p t2)
  = RAllP p $ strengthenRefType_ f t1 t2

strengthenRefType_ f (RAllS s t1) t2
  = RAllS s $ strengthenRefType_ f t1 t2

strengthenRefType_ f t1 (RAllS s t2)
  = RAllS s $ strengthenRefType_ f t1 t2

strengthenRefType_ f (RAllE x tx t1) (RAllE y ty t2) | x == y
  = RAllE x (strengthenRefType_ f tx ty) $ strengthenRefType_ f t1 t2

strengthenRefType_ f (RAllE x tx t1) t2
  = RAllE x tx $ strengthenRefType_ f t1 t2

strengthenRefType_ f t1 (RAllE x tx t2)
  = RAllE x tx $ strengthenRefType_ f t1 t2

strengthenRefType_ f (RAppTy t1 t1' r1) (RAppTy t2 t2' r2)
  = RAppTy t t' (r1 `meet` r2)
    where t  = strengthenRefType_ f t1 t2
          t' = strengthenRefType_ f t1' t2'

strengthenRefType_ f (RImpF x1 t1 t1' r1) (RImpF x2 t2 t2' r2)
  = RImpF x2 t t' (r1 `meet` r2)
    where t  = strengthenRefType_ f t1 t2
          t' = strengthenRefType_ f (subst1 t1' (x1, EVar x2)) t2'

strengthenRefType_ f (RFun x1 t1 t1' r1) (RFun x2 t2 t2' r2)
  = RFun x2 t t' (r1 `meet` r2)
    where t  = strengthenRefType_ f t1 t2
          t' = strengthenRefType_ f (subst1 t1' (x1, EVar x2)) t2'

strengthenRefType_ f (RApp tid t1s rs1 r1) (RApp _ t2s rs2 r2)
  = RApp tid ts rs (r1 `meet` r2)
    where ts  = zipWith (strengthenRefType_ f) t1s t2s
          rs  = meets rs1 rs2


strengthenRefType_ _ (RVar v1 r1)  (RVar v2 r2) | v1 == v2
  = RVar v1 (r1 `meet` r2)
strengthenRefType_ f t1 t2
  = f t1 t2

meets :: (F.Reftable r) => [r] -> [r] -> [r]
meets [] rs                 = rs
meets rs []                 = rs
meets rs rs'
  | length rs == length rs' = zipWith meet rs rs'
  | otherwise               = panic Nothing "meets: unbalanced rs"

strengthen :: Reftable r => RType c tv r -> r -> RType c tv r
strengthen (RApp c ts rs r) r'  = RApp c ts rs (r `F.meet` r')
strengthen (RVar a r) r'        = RVar a       (r `F.meet` r')
strengthen (RImpF b t1 t2 r) r'  = RImpF b t1 t2 (r `F.meet` r')
strengthen (RFun b t1 t2 r) r'  = RFun b t1 t2 (r `F.meet` r')
strengthen (RAppTy t1 t2 r) r'  = RAppTy t1 t2 (r `F.meet` r')
strengthen t _                  = t


quantifyRTy :: Eq tv => [RTVar tv (RType c tv ())] -> RType c tv r -> RType c tv r
quantifyRTy tvs ty = foldr RAllT ty tvs

quantifyFreeRTy :: Eq tv => RType c tv r -> RType c tv r
quantifyFreeRTy ty = quantifyRTy (freeTyVars ty) ty


-------------------------------------------------------------------------
addTyConInfo :: (PPrint r, Reftable r, SubsTy RTyVar (RType RTyCon RTyVar ()) r, Reftable (RTProp RTyCon RTyVar r))
             => TCEmb TyCon
             -> (M.HashMap TyCon RTyCon)
             -> RRType r
             -> RRType r
-------------------------------------------------------------------------
addTyConInfo tce tyi = mapBot (expandRApp tce tyi)

-------------------------------------------------------------------------
expandRApp :: (PPrint r, Reftable r, SubsTy RTyVar (RType RTyCon RTyVar ()) r, Reftable (RTProp RTyCon RTyVar r))
           => TCEmb TyCon
           -> (M.HashMap TyCon RTyCon)
           -> RRType r
           -> RRType r
-------------------------------------------------------------------------
expandRApp tce tyi t@(RApp {}) = RApp rc' ts rs' r
  where
    RApp rc ts rs r            = t
    rc'                        = appRTyCon tce tyi rc as
    pvs                        = rTyConPVs rc'
    rs'                        = applyNonNull rs0 (rtPropPV rc pvs) rs
    rs0                        = rtPropTop <$> pvs
    n                          = length fVs
    fVs                        = GM.tyConTyVarsDef $ rtc_tc rc
    as                         = choosen n ts (rVar <$> fVs)

    choosen 0 _ _           = []
    choosen i (x:xs) (_:ys) = x:choosen (i-1) xs ys
    choosen i []     (y:ys) = y:choosen (i-1) [] ys
    choosen _ _ _           = impossible Nothing "choosen: this cannot happen"

expandRApp _ _ t               = t

rtPropTop
  :: (OkRT c tv r,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
   => PVar (RType c tv ()) -> Ref (RType c tv ()) (RType c tv r)
rtPropTop pv = case ptype pv of
                 PVProp t -> RProp xts $ ofRSort t
                 PVHProp  -> RProp xts $ mempty
               where
                 xts      =  pvArgs pv

rtPropPV :: (Fixpoint a, Reftable r)
         => a
         -> [PVar (RType c tv ())]
         -> [Ref (RType c tv ()) (RType c tv r)]
         -> [Ref (RType c tv ()) (RType c tv r)]
rtPropPV _rc = zipWith mkRTProp

mkRTProp :: Reftable r
         => PVar (RType c tv ())
         -> Ref (RType c tv ()) (RType c tv r)
         -> Ref (RType c tv ()) (RType c tv r)
mkRTProp pv (RProp ss (RHole r))
  = RProp ss $ (ofRSort $ pvType pv) `strengthen` r

mkRTProp pv (RProp ss t)
  | length (pargs pv) == length ss
  = RProp ss t
  | otherwise
  = RProp (pvArgs pv) t

pvArgs :: PVar t -> [(Symbol, t)]
pvArgs pv = [(s, t) | (t, s, _) <- pargs pv]


appRTyCon :: SubsTy RTyVar (RType c RTyVar ()) RPVar
          => TCEmb TyCon
          -> M.HashMap TyCon RTyCon
          -> RTyCon
          -> [RType c RTyVar r]
          -> RTyCon
appRTyCon tce tyi rc ts = RTyCon c ps' (rtc_info rc'')
  where
    c    = rtc_tc rc
    ps'  = subts (zip (RTV <$> αs) ts') <$> rTyConPVs rc'
    ts'  = if null ts then rVar <$> βs else toRSort <$> ts
    rc'  = M.lookupDefault rc c tyi
    αs   = GM.tyConTyVarsDef $ rtc_tc rc'
    βs   = GM.tyConTyVarsDef c
    rc'' = if isNumeric tce rc' then addNumSizeFun rc' else rc'


-- RJ: The code of `isNumeric` is incomprehensible.
-- Please fix it to use intSort instead of intFTyCon
isNumeric :: TCEmb TyCon -> RTyCon -> Bool
isNumeric tce c = mySort == FTC F.intFTyCon || mySort == F.FInt
  where
    -- mySort      = M.lookupDefault def rc tce
    mySort      = maybe def fst (F.tceLookup rc tce)
    def         = FTC . symbolFTycon . dummyLoc . tyConName $ rc
    rc          = rtc_tc c

addNumSizeFun :: RTyCon -> RTyCon
addNumSizeFun c
  = c {rtc_info = (rtc_info c) {sizeFunction = Just IdSizeFun } }


generalize :: (Eq tv) => RType c tv r -> RType c tv r
generalize t = mkUnivs (freeTyVars t) [] [] t

freeTyVars :: Eq tv => RType c tv r -> [RTVar tv (RType c tv ())]
freeTyVars (RAllP _ t)     = freeTyVars t
freeTyVars (RAllS _ t)     = freeTyVars t
freeTyVars (RAllT α t)     = freeTyVars t L.\\ [α]
freeTyVars (RImpF _ t t' _)= freeTyVars t `L.union` freeTyVars t'
freeTyVars (RFun _ t t' _) = freeTyVars t `L.union` freeTyVars t'
freeTyVars (RApp _ ts _ _) = L.nub $ concatMap freeTyVars ts
freeTyVars (RVar α _)      = [makeRTVar α]
freeTyVars (RAllE _ tx t)  = freeTyVars tx `L.union` freeTyVars t
freeTyVars (REx _ tx t)    = freeTyVars tx `L.union` freeTyVars t
freeTyVars (RExprArg _)    = []
freeTyVars (RAppTy t t' _) = freeTyVars t `L.union` freeTyVars t'
freeTyVars (RHole _)       = []
freeTyVars (RRTy e _ _ t)  = L.nub $ concatMap freeTyVars (t:(snd <$> e))


tyClasses :: (OkRT RTyCon tv r) => RType RTyCon tv r -> [(Class, [RType RTyCon tv r])]
tyClasses (RAllP _ t)     = tyClasses t
tyClasses (RAllS _ t)     = tyClasses t
tyClasses (RAllT _ t)     = tyClasses t
tyClasses (RAllE _ _ t)   = tyClasses t
tyClasses (REx _ _ t)     = tyClasses t
tyClasses (RImpF _ t t' _) = tyClasses t ++ tyClasses t'
tyClasses (RFun _ t t' _) = tyClasses t ++ tyClasses t'
tyClasses (RAppTy t t' _) = tyClasses t ++ tyClasses t'
tyClasses (RApp c ts _ _)
  | Just cl <- tyConClass_maybe $ rtc_tc c
  = [(cl, ts)]
  | otherwise
  = []
tyClasses (RVar _ _)      = []
tyClasses (RRTy _ _ _ t)  = tyClasses t
tyClasses (RHole _)       = []
tyClasses t               = panic Nothing ("RefType.tyClasses cannot handle" ++ show t)


--------------------------------------------------------------------------------
-- TODO: Rewrite subsTyvars with Traversable
--------------------------------------------------------------------------------

subsTyVars_meet
  :: (Eq tv, Foldable t, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => t (tv, RType c tv (), RType c tv r) -> RType c tv r -> RType c tv r
subsTyVars_meet        = subsTyVars True

subsTyVars_nomeet
  :: (Eq tv, Foldable t, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => t (tv, RType c tv (), RType c tv r) -> RType c tv r -> RType c tv r
subsTyVars_nomeet      = subsTyVars False

subsTyVar_nomeet
  :: (Eq tv, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => (tv, RType c tv (), RType c tv r) -> RType c tv r -> RType c tv r
subsTyVar_nomeet       = subsTyVar False

subsTyVar_meet
  :: (Eq tv, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => (tv, RType c tv (), RType c tv r) -> RType c tv r -> RType c tv r
subsTyVar_meet         = subsTyVar True

subsTyVar_meet'
  :: (Eq tv, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => (tv, RType c tv r) -> RType c tv r -> RType c tv r
subsTyVar_meet' (α, t) = subsTyVar_meet (α, toRSort t, t)

subsTyVars
  :: (Eq tv, Foldable t, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => Bool
  -> t (tv, RType c tv (), RType c tv r)
  -> RType c tv r
  -> RType c tv r
subsTyVars meet ats t = foldl' (flip (subsTyVar meet)) t ats

subsTyVar
  :: (Eq tv, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => Bool
  -> (tv, RType c tv (), RType c tv r)
  -> RType c tv r
  -> RType c tv r
subsTyVar meet        = subsFree meet S.empty

subsFree
  :: (Eq tv, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => Bool
  -> S.HashSet tv
  -> (tv, RType c tv (), RType c tv r)
  -> RType c tv r
  -> RType c tv r
subsFree m s z (RAllS l t)
  = RAllS l (subsFree m s z t)
subsFree m s z@(α, τ,_) (RAllP π t)
  = RAllP (subt (α, τ) π) (subsFree m s z t)
subsFree m s z@(a, τ, _) (RAllT α t)
  -- subt inside the type variable instantiates the kind of the variable
  = RAllT (subt (a, τ) α) $ subsFree m (ty_var_value α `S.insert` s) z t
subsFree m s z@(α, τ, _) (RImpF x t t' r)
  = RImpF x (subsFree m s z t) (subsFree m s z t') (subt (α, τ) r)
subsFree m s z@(α, τ, _) (RFun x t t' r)
  = RFun x (subsFree m s z t) (subsFree m s z t') (subt (α, τ) r)
subsFree m s z@(α, τ, _) (RApp c ts rs r)
  = RApp (subt z' c) (subsFree m s z <$> ts) (subsFreeRef m s z <$> rs) (subt (α, τ) r)
    where z' = (α, τ) -- UNIFY: why instantiating INSIDE parameters?
subsFree meet s (α', τ, t') (RVar α r)
  | α == α' && not (α `S.member` s)
  = if meet then t' `strengthen` (subt (α, τ) r) else t'
  | otherwise
  = RVar (subt (α', τ) α) r
subsFree m s z (RAllE x t t')
  = RAllE x (subsFree m s z t) (subsFree m s z t')
subsFree m s z (REx x t t')
  = REx x (subsFree m s z t) (subsFree m s z t')
subsFree m s z@(α, τ, _) (RAppTy t t' r)
  = subsFreeRAppTy m s (subsFree m s z t) (subsFree m s z t') (subt (α, τ) r)
subsFree _ _ _ t@(RExprArg _)
  = t
subsFree m s z@(α, τ, _) (RRTy e r o t)
  = RRTy (mapSnd (subsFree m s z) <$> e) (subt (α, τ) r) o (subsFree m s z t)
subsFree _ _ (α, τ, _) (RHole r)
  = RHole (subt (α, τ) r)

subsFrees
  :: (Eq tv, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => Bool
  -> S.HashSet tv
  -> [(tv, RType c tv (), RType c tv r)]
  -> RType c tv r
  -> RType c tv r
subsFrees m s zs t = foldl' (flip (subsFree m s)) t zs

-- GHC INVARIANT: RApp is Type Application to something other than TYCon
subsFreeRAppTy
  :: (Eq tv, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()),
      FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => Bool
  -> S.HashSet tv
  -> RType c tv r
  -> RType c tv r
  -> r
  -> RType c tv r
subsFreeRAppTy m s (RApp c ts rs r) t' r'
  = mkRApp m s c (ts ++ [t']) rs r r'
subsFreeRAppTy _ _ t t' r'
  = RAppTy t t' r'

mkRApp
  :: (Eq tv, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => Bool
  -> S.HashSet tv
  -> c
  -> [RType c tv r]
  -> [RTProp c tv r]
  -> r
  -> r
  -> RType c tv r
mkRApp m s c ts rs r r'
  | isFun c, [t1, t2] <- ts
  = RFun dummySymbol t1 t2 $ refAppTyToFun r'
  | otherwise
  = subsFrees m s zs $ RApp c ts rs $ r `meet` r' -- (refAppTyToApp r')
  where
    zs = [(tv, toRSort t, t) | (tv, t) <- zip (freeVars c) ts]

refAppTyToFun :: Reftable r => r -> r
refAppTyToFun r
  | isTauto r = r
  | otherwise = panic Nothing "RefType.refAppTyToFun"

subsFreeRef
  :: (Eq tv, Hashable tv, Reftable r, TyConable c,
      SubsTy tv (RType c tv ()) c, SubsTy tv (RType c tv ()) r,
      SubsTy tv (RType c tv ()) (RType c tv ()), FreeVar c tv,
      SubsTy tv (RType c tv ()) tv,
      SubsTy tv (RType c tv ()) (RTVar tv (RType c tv ())))
  => Bool
  -> S.HashSet tv
  -> (tv, RType c tv (), RType c tv r)
  -> RTProp c tv r
  -> RTProp c tv r
subsFreeRef _ _ (α', τ', _) (RProp ss (RHole r))
  = RProp (mapSnd (subt (α', τ')) <$> ss) (RHole r)
subsFreeRef m s (α', τ', t')  (RProp ss t)
  = RProp (mapSnd (subt (α', τ')) <$> ss) $ subsFree m s (α', τ', fmap top t') t


--------------------------------------------------------------------------------
-- | Type Substitutions --------------------------------------------------------
--------------------------------------------------------------------------------

subts :: (SubsTy tv ty c) => [(tv, ty)] -> c -> c
subts = flip (foldr subt)

instance SubsTy RTyVar (RType RTyCon RTyVar ()) RTyVar where
  subt (RTV x, t) (RTV z) | isTyVar z, tyVarKind z == TyVarTy x
    = RTV (setVarType z $ toType t)
  subt _ v
    = v

instance SubsTy RTyVar (RType RTyCon RTyVar ()) (RTVar RTyVar (RType RTyCon RTyVar ())) where
  -- NV TODO: update kind
  subt su rty = rty { ty_var_value = subt su $ ty_var_value rty }


instance SubsTy BTyVar (RType c BTyVar ()) BTyVar where
  subt _ = id

instance SubsTy BTyVar (RType c BTyVar ()) (RTVar BTyVar (RType c BTyVar ())) where
  subt _ = id

instance SubsTy tv ty ()   where
  subt _ = id

instance SubsTy tv ty Symbol where
  subt _ = id



instance (SubsTy tv ty Expr) => SubsTy tv ty Reft where
  subt su (Reft (x, e)) = Reft (x, subt su e)


instance (SubsTy tv ty Sort) => SubsTy tv ty Expr where
  subt su (ELam (x, s) e) = ELam (x, subt su s) $ subt su e
  subt su (EApp e1 e2)    = EApp (subt su e1) (subt su e2)
  subt su (ENeg e)        = ENeg (subt su e)
  subt su (PNot e)        = PNot (subt su e)
  subt su (EBin b e1 e2)  = EBin b (subt su e1) (subt su e2)
  subt su (EIte e e1 e2)  = EIte (subt su e) (subt su e1) (subt su e2)
  subt su (ECst e s)      = ECst (subt su e) (subt su s)
  subt su (ETApp e s)     = ETApp (subt su e) (subt su s)
  subt su (ETAbs e x)     = ETAbs (subt su e) x
  subt su (PAnd es)       = PAnd (subt su <$> es)
  subt su (POr  es)       = POr  (subt su <$> es)
  subt su (PImp e1 e2)    = PImp (subt su e1) (subt su e2)
  subt su (PIff e1 e2)    = PIff (subt su e1) (subt su e2)
  subt su (PAtom b e1 e2) = PAtom b (subt su e1) (subt su e2)
  subt su (PAll xes e)    = PAll (subt su <$> xes) (subt su e)
  subt su (PExist xes e)  = PExist (subt su <$> xes) (subt su e)
  subt _ e                = e

instance (SubsTy tv ty a, SubsTy tv ty b) => SubsTy tv ty (a, b) where
  subt su (x, y) = (subt su x, subt su y)

instance SubsTy BTyVar (RType BTyCon BTyVar ()) Sort where
  subt (v, RVar α _) (FObj s)
    | symbol v == s = FObj $ symbol α
    | otherwise     = FObj s
  subt _ s          = s


instance SubsTy Symbol RSort Sort where
  subt (v, RVar α _) (FObj s)
    | symbol v == s = FObj $ symbol {- rTyVarSymbol -} α
    | otherwise     = FObj s
  subt _ s          = s


instance SubsTy RTyVar RSort Sort where
  subt (v, sv) (FObj s)
    | symbol v == s = typeSort mempty (toType sv)
    | otherwise     = FObj s
  subt _ s          = s

instance (SubsTy tv ty ty) => SubsTy tv ty (PVKind ty) where
  subt su (PVProp t) = PVProp (subt su t)
  subt _   PVHProp   = PVHProp

instance (SubsTy tv ty ty) => SubsTy tv ty (PVar ty) where
  subt su (PV n t v xts) = PV n (subt su t) v [(subt su t, x, y) | (t,x,y) <- xts]

instance SubsTy RTyVar RSort RTyCon where
   subt z c = RTyCon tc ps' i
     where
       tc   = rtc_tc c
       ps'  = subt z <$> rTyConPVs c
       i    = rtc_info c

-- NOTE: This DOES NOT substitute at the binders
instance SubsTy RTyVar RSort PrType where
  subt (α, τ) = subsTyVar_meet (α, τ, ofRSort τ)

instance SubsTy RTyVar RSort SpecType where
  subt (α, τ) = subsTyVar_meet (α, τ, ofRSort τ)

instance SubsTy TyVar Type SpecType where
  subt (α, τ) = subsTyVar_meet (RTV α, ofType τ, ofType τ)

instance SubsTy RTyVar RTyVar SpecType where
  subt (α, a) = subt (α, RVar a () :: RSort)


instance SubsTy RTyVar RSort RSort where
  subt (α, τ) = subsTyVar_meet (α, τ, ofRSort τ)

instance SubsTy tv RSort Predicate where
  subt _ = id -- NV TODO

instance (SubsTy tv ty r) => SubsTy tv ty (UReft r) where
  subt su r = r {ur_reft = subt su $ ur_reft r}

-- Here the "String" is a Bare-TyCon. TODO: wrap in newtype
instance SubsTy BTyVar BSort BTyCon where
  subt _ t = t

instance SubsTy BTyVar BSort BSort where
  subt (α, τ) = subsTyVar_meet (α, τ, ofRSort τ)

instance (SubsTy tv ty (UReft r), SubsTy tv ty (RType c tv ())) => SubsTy tv ty (RTProp c tv (UReft r))  where
  subt m (RProp ss (RHole p)) = RProp ((mapSnd (subt m)) <$> ss) $ RHole $ subt m p
  subt m (RProp ss t) = RProp ((mapSnd (subt m)) <$> ss) $ fmap (subt m) t

subvUReft     :: (UsedPVar -> UsedPVar) -> UReft Reft -> UReft Reft
subvUReft f (MkUReft r p s) = MkUReft r (subvPredicate f p) s

subvPredicate :: (UsedPVar -> UsedPVar) -> Predicate -> Predicate
subvPredicate f (Pr pvs) = Pr (f <$> pvs)

--------------------------------------------------------------------------------
ofType :: Monoid r => Type -> RRType r
--------------------------------------------------------------------------------
ofType      = ofType_ $ TyConv
  { tcFVar  = rVar
  , tcFTVar = rTVar
  , tcFApp  = \c ts -> rApp c ts [] mempty
  , tcFLit  = ofLitType rApp
  }

--------------------------------------------------------------------------------
bareOfType :: Monoid r => Type -> BRType r
--------------------------------------------------------------------------------
bareOfType  = ofType_ $ TyConv
  { tcFVar  = (`RVar` mempty) . BTV . symbol
  , tcFTVar = bTVar
  , tcFApp  = \c ts -> bApp c ts [] mempty
  , tcFLit  = ofLitType bApp
  }

--------------------------------------------------------------------------------
ofType_ :: Monoid r => TyConv c tv r -> Type -> RType c tv r
--------------------------------------------------------------------------------
ofType_ tx = go . expandTypeSynonyms
  where
    go (TyVarTy α)
      = tcFVar tx α
    go (FunTy τ τ')
      = rFun dummySymbol (go τ) (go τ')
    go (ForAllTy (TvBndr α _) τ)
      = RAllT (tcFTVar tx α) $ go τ
    go (TyConApp c τs)
      | Just (αs, τ) <- TC.synTyConDefn_maybe c
      = go (substTyWith αs τs τ)
      | otherwise
      = tcFApp tx c (go <$> τs) -- [] mempty
    go (AppTy t1 t2)
      = RAppTy (go t1) (ofType_ tx t2) mempty
    go (LitTy x)
      = tcFLit tx x
    go (CastTy t _)
      = go t
    go (CoercionTy _)
      = errorstar "Coercion is currently not supported"

ofLitType :: (Monoid r) => (TyCon -> [t] -> [p] -> r -> t) -> TyLit -> t
ofLitType rF (NumTyLit _) = rF intTyCon [] [] mempty
ofLitType rF (StrTyLit _) = rF listTyCon [rF charTyCon [] [] mempty] [] mempty

data TyConv c tv r = TyConv
  { tcFVar  :: TyVar -> RType c tv r
  , tcFTVar :: TyVar -> RTVar tv (RType c tv ())
  , tcFApp  :: TyCon -> [RType c tv r] -> RType c tv r
  , tcFLit  :: TyLit -> RType c tv r
  }

--------------------------------------------------------------------------------
-- | Converting to Fixpoint ----------------------------------------------------
--------------------------------------------------------------------------------


instance Expression Var where
  expr   = eVar

-- TODO: turn this into a map lookup?
dataConReft ::  DataCon -> [Symbol] -> Reft
dataConReft c []
  | c == trueDataCon
  = predReft $ eProp vv_
  | c == falseDataCon
  = predReft $ PNot $ eProp vv_

dataConReft c [x]
  | c == intDataCon
  = symbolReft x -- OLD (vv_, [RConc (PAtom Eq (EVar vv_) (EVar x))])
dataConReft c _
  | not $ isBaseDataCon c
  = mempty
dataConReft c xs
  = exprReft dcValue -- OLD Reft (vv_, [RConc (PAtom Eq (EVar vv_) dcValue)])
  where
    dcValue
      | null xs && null (dataConUnivTyVars c)
      = EVar $ symbol c
      | otherwise
      = mkEApp (dummyLoc $ symbol c) (eVar <$> xs)

isBaseDataCon :: DataCon -> Bool
isBaseDataCon c = and $ isBaseTy <$> dataConOrigArgTys c ++ dataConRepArgTys c

isBaseTy :: Type -> Bool
isBaseTy (TyVarTy _)     = True
isBaseTy (AppTy _ _)     = False
isBaseTy (TyConApp _ ts) = and $ isBaseTy <$> ts
isBaseTy (FunTy _ _)     = False
isBaseTy (ForAllTy _ _)  = False
isBaseTy (LitTy _)       = True
isBaseTy (CastTy _ _)    = False
isBaseTy (CoercionTy _)  = False


dataConMsReft :: Reftable r => RType c tv r -> [Symbol] -> Reft
dataConMsReft ty ys  = subst su (rTypeReft (ignoreOblig $ ty_res trep))
  where
    trep = toRTypeRep ty
    xs   = ty_binds trep
    ts   = ty_args  trep
    su   = mkSubst $ [(x, EVar y) | ((x, _), y) <- zip (zip xs ts) ys]

--------------------------------------------------------------------------------
-- | Embedding RefTypes --------------------------------------------------------
--------------------------------------------------------------------------------

type ToTypeable r = (Reftable r, PPrint r, SubsTy RTyVar (RRType ()) r, Reftable (RTProp RTyCon RTyVar r))

-- TODO: remove toType, generalize typeSort
toType  :: (ToTypeable r) => RRType r -> Type
toType (RImpF x t t' r)
 = toType (RFun x t t' r)
toType (RFun _ t t' _)
  = FunTy (toType t) (toType t')
toType (RAllT a t) | RTV α <- ty_var_value a
  = ForAllTy (TvBndr α Required) (toType t)
toType (RAllP _ t)
  = toType t
toType (RAllS _ t)
  = toType t
toType (RVar (RTV α) _)
  = TyVarTy α
toType (RApp (RTyCon {rtc_tc = c}) ts _ _)
  = TyConApp c (toType <$> filter notExprArg ts)
  where
    notExprArg (RExprArg _) = False
    notExprArg _            = True
toType (RAllE _ _ t)
  = toType t
toType (REx _ _ t)
  = toType t
toType (RAppTy t (RExprArg _) _)
  = toType t
toType (RAppTy t t' _)
  = AppTy (toType t) (toType t')
toType t@(RExprArg _)
  = impossible Nothing $ "CANNOT HAPPEN: RefType.toType called with: " ++ show t
toType (RRTy _ _ _ t)
  = toType t
toType t
  = impossible Nothing $ "RefType.toType cannot handle: " ++ show t


--------------------------------------------------------------------------------
-- | Annotations and Solutions -------------------------------------------------
--------------------------------------------------------------------------------

rTypeSortedReft ::  (PPrint r, Reftable r, SubsTy RTyVar (RType RTyCon RTyVar ()) r, Reftable (RTProp RTyCon RTyVar r))
                => TCEmb TyCon -> RRType r -> SortedReft
rTypeSortedReft emb t = RR (rTypeSort emb t) (rTypeReft t)

rTypeSort     ::  (PPrint r, Reftable r, SubsTy RTyVar (RType RTyCon RTyVar ()) r, Reftable (RTProp RTyCon RTyVar r))
              => TCEmb TyCon -> RRType r -> Sort
rTypeSort tce = typeSort tce . toType

--------------------------------------------------------------------------------
applySolution :: (Functor f) => FixSolution -> f SpecType -> f SpecType
--------------------------------------------------------------------------------
applySolution = fmap . fmap . mapReft . appSolRefa
  where
    mapReft f (MkUReft (Reft (x, z)) p s) = MkUReft (Reft (x, f z)) p s

appSolRefa :: Visitable t
           => M.HashMap KVar Expr -> t -> t
appSolRefa s p = mapKVars f p
  where
    f k        = Just $ M.lookupDefault PTop k s

--------------------------------------------------------------------------------
shiftVV :: SpecType -> Symbol -> SpecType
--------------------------------------------------------------------------------
shiftVV t@(RApp _ ts rs r) vv'
  = t { rt_args  = subst1 ts (rTypeValueVar t, EVar vv') }
      { rt_pargs = subst1 rs (rTypeValueVar t, EVar vv') }
      { rt_reft  = (`F.shiftVV` vv') <$> r }

shiftVV t@(RImpF _ _ _ r) vv'
  = t { rt_reft = (`F.shiftVV` vv') <$> r }

shiftVV t@(RFun _ _ _ r) vv'
  = t { rt_reft = (`F.shiftVV` vv') <$> r }

shiftVV t@(RAppTy _ _ r) vv'
  = t { rt_reft = (`F.shiftVV` vv') <$> r }

shiftVV t@(RVar _ r) vv'
  = t { rt_reft = (`F.shiftVV` vv') <$> r }

shiftVV t _
  = t -- errorstar $ "shiftVV: cannot handle " ++ showpp t


--------------------------------------------------------------------------------
-- |Auxiliary Stuff Used Elsewhere ---------------------------------------------
--------------------------------------------------------------------------------

-- MOVE TO TYPES
instance (Show tv, Show ty) => Show (RTAlias tv ty) where
  show (RTA n as xs t p _) =
    printf "type %s %s %s = %s -- defined at %s" (symbolString n)
      (unwords (show <$> as))
      (unwords (show <$> xs))
      (show t) (show p)

--------------------------------------------------------------------------------
-- | From Old Fixpoint ---------------------------------------------------------
--------------------------------------------------------------------------------
typeSort :: TCEmb TyCon -> Type -> Sort
typeSort tce = go
  where
    go :: Type -> Sort
    go t@(FunTy _ _)    = typeSortFun tce t
    go τ@(ForAllTy _ _) = typeSortForAll tce τ
    -- go (TyConApp c τs)  = fApp (tyConFTyCon tce c) (go <$> τs)
    go (TyConApp c τs)  = tyConFTyCon tce c (go <$> τs)
    go (AppTy t1 t2)    = fApp (go t1) [go t2]
    go (TyVarTy tv)     = tyVarSort tv
    go (CastTy t _)     = go t
    go τ                = FObj (typeUniqueSymbol τ)

tyConFTyCon :: TCEmb TyCon -> TyCon -> [Sort] -> Sort
tyConFTyCon tce c ts = case tceLookup c tce of 
                         Just (t, WithArgs) -> t 
                         Just (t, NoArgs)   -> fApp t ts  
                         Nothing            -> fApp (fTyconSort niTc) ts 
  where
    niTc             = symbolNumInfoFTyCon (dummyLoc $ tyConName c) (isNumCls c) (isFracCls c)
    -- oldRes           = F.notracepp _msg $ M.lookupDefault def c tce
    -- _msg             = "tyConFTyCon c = " ++ show c ++ "default " ++ show (def, TC.isFamInstTyCon c)

tyVarSort :: TyVar -> Sort
tyVarSort = FObj . symbol 

typeUniqueSymbol :: Type -> Symbol
typeUniqueSymbol = symbol . GM.typeUniqueString

typeSortForAll :: TCEmb TyCon -> Type -> Sort
typeSortForAll tce τ  = genSort $ typeSort tce tbody
  where
    genSort t         = foldl' (flip FAbs) (sortSubst su t) [0..n-1]
    (as, tbody)       = F.notracepp ("splitForallTys" ++ GM.showPpr τ) (splitForAllTys τ)
    su                = M.fromList $ zip sas (FVar <$>  [0..])
    sas               = symbol <$> as
    n                 = length as

-- RJ: why not make this the Symbolic instance?
tyConName :: TyCon -> Symbol
tyConName c
  | listTyCon == c    = listConName
  | TC.isTupleTyCon c = tupConName
  | otherwise         = symbol c

typeSortFun :: TCEmb TyCon -> Type -> Sort
typeSortFun tce t -- τ1 τ2
  = mkFFunc 0 sos
  where sos  = typeSort tce <$> τs
        τs   = grabArgs [] t

grabArgs :: [Type] -> Type -> [Type]
grabArgs τs (FunTy τ1 τ2)
  | Just a <- stringClassArg τ1
  = grabArgs τs (mapType (\t -> if t == a then stringTy else t) τ2)
  | not $ isClassPred τ1
  = grabArgs (τ1:τs) τ2
  | otherwise
  = grabArgs τs τ2
grabArgs τs τ
  = reverse (τ:τs)

-- mkDataConIdsTy :: (PPrint r, Reftable r, SubsTy RTyVar (RType RTyCon RTyVar ()) r, Reftable (RTProp RTyCon RTyVar r))
--                => DataCon -> RType RTyCon RTyVar r -> [(Var, RType RTyCon RTyVar r)]
-- mkDataConIdsTy dc t = (`expandProductType` t) <$> dataConImplicitIds dc

expandProductType :: (PPrint r, Reftable r, SubsTy RTyVar (RType RTyCon RTyVar ()) r, Reftable (RTProp RTyCon RTyVar r))
                  => Var -> RType RTyCon RTyVar r -> RType RTyCon RTyVar r
expandProductType x t
  | isTrivial       = t
  | otherwise       = fromRTypeRep $ trep {ty_binds = xs', ty_args = ts', ty_refts = rs'}
     where
      isTrivial     = ofType (varType x) == toRSort t
      τs            = fst $ splitFunTys $ snd $ splitForAllTys $ toType t
      trep          = toRTypeRep t
      (xs',ts',rs') = unzip3 $ concatMap mkProductTy $ zip4 τs (ty_binds trep) (ty_args trep) (ty_refts trep)

-- splitFunTys :: Type -> ([Type], Type)


mkProductTy :: (Monoid t, Monoid r)
            => (Type, Symbol, RType RTyCon RTyVar r, t)
            -> [(Symbol, RType RTyCon RTyVar r, t)]
mkProductTy (τ, x, t, r) = maybe [(x, t, r)] f $ deepSplitProductType_maybe menv τ
  where
    f    = map ((dummySymbol, , mempty) . ofType . fst) . third4
    menv = (emptyFamInstEnv, emptyFamInstEnv)

-----------------------------------------------------------------------------------------
-- | Binders generated by class predicates, typically for constraining tyvars (e.g. FNum)
-----------------------------------------------------------------------------------------
classBinds :: TCEmb TyCon -> SpecType -> [(Symbol, SortedReft)]
classBinds _ (RApp c ts _ _)
  | isFracCls c
  = [(symbol a, trueSortedReft FFrac) | (RVar a _) <- ts]
  | isNumCls c
  = [(symbol a, trueSortedReft FNum) | (RVar a _) <- ts]
classBinds emb (RApp c [_, _, (RVar a _), t] _ _)
  | isEqual c
  = [(symbol a, rTypeSortedReft emb t)]
classBinds  emb (RApp c [_, (RVar a _), t] _ _)
  | showpp c == "Data.Type.Equality.~"  -- see [NOTE:type-equality-hack]
  = [(symbol a, rTypeSortedReft emb t)]
classBinds _ t
  = notracepp ("CLASSBINDS: " ++ showpp (toType t, isEqualityConstr t)) []

{- | [NOTE:type-equality-hack]

God forgive me for this AWFUL HACK.

How can I “test for” (i.e. write a function of type `Type -> Bool`)

that returns `True` for values (i.e. `Type`s) that print out as:

 ```
     typ ~ GHC.Types.Int
 ```

 or with, which some more detail, looks like

 ```
    (~ (TYPE LiftedRep) typ GHC.Types.Int)
 ```

 and which are generated from Haskell source that looks like

 ```
 instance PersistEntity Blob where
    data EntityField Blob typ
       = typ ~ Int => BlobXVal |
         typ ~ Int => BlobYVal
 ```

 see tests/neg/BinahUpdateLib1.hs

 I would have thought that `Type.isEqPred` or `Type.isNomEqPred` described here

 https://downloads.haskell.org/~ghc/8.2.1/docs/html/libraries/ghc-8.2.1/src/Type.html#isEqPred

 and which is what `isEqualityConstr` below is doing, but alas it doesn't work.
-}

isEqualityConstr :: SpecType -> Bool
isEqualityConstr = (isEqPred  .||. isNomEqPred) . toType

--------------------------------------------------------------------------------
-- | Termination Predicates ----------------------------------------------------
--------------------------------------------------------------------------------

makeNumEnv :: (Foldable t, TyConable c) => t (RType c b t1) -> [b]
makeNumEnv = concatMap go
  where
    go (RApp c ts _ _) | isNumCls c || isFracCls c = [ a | (RVar a _) <- ts]
    go _ = []

isDecreasing :: S.HashSet TyCon -> [RTyVar] -> SpecType -> Bool
isDecreasing autoenv  _ (RApp c _ _ _)
  =  isJust (sizeFunction (rtc_info c)) -- user specified size or
  || isSizeable autoenv tc
  where tc = rtc_tc c
isDecreasing _ cenv (RVar v _)
  = v `elem` cenv
isDecreasing _ _ _
  = False

makeDecrType :: Symbolic a
             => S.HashSet TyCon
             -> [(a, (Symbol, RType RTyCon t (UReft Reft)))]
             -> (Symbol, RType RTyCon t (UReft Reft))
makeDecrType autoenv = mkDType autoenv [] []

mkDType :: Symbolic a
        => S.HashSet TyCon
        -> [(Symbol, Symbol, Symbol -> Expr)]
        -> [Expr]
        -> [(a, (Symbol, RType RTyCon t (UReft Reft)))]
        -> (Symbol, RType RTyCon t (UReft Reft))
mkDType autoenv xvs acc [(v, (x, t))]
  = (x, ) $ t `strengthen` tr
  where
    tr = uTop $ Reft (vv, pOr (r:acc))
    r  = cmpLexRef xvs (v', vv, f)
    v' = symbol v
    f  = mkDecrFun autoenv  t
    vv = "vvRec"

mkDType autoenv xvs acc ((v, (x, t)):vxts)
  = mkDType autoenv ((v', x, f):xvs) (r:acc) vxts
  where
    r  = cmpLexRef xvs  (v', x, f)
    v' = symbol v
    f  = mkDecrFun autoenv t


mkDType _ _ _ _
  = panic Nothing "RefType.mkDType called on invalid input"

isSizeable  :: S.HashSet TyCon -> TyCon -> Bool
isSizeable autoenv tc = S.member tc autoenv --   TC.isAlgTyCon tc -- && TC.isRecursiveTyCon tc

mkDecrFun :: S.HashSet TyCon -> RType RTyCon t t1 -> Symbol -> Expr
mkDecrFun autoenv (RApp c _ _ _)
  | Just f <- szFun <$> sizeFunction (rtc_info c)
  = f
  | isSizeable autoenv $ rtc_tc c
  = \v -> F.mkEApp lenLocSymbol [F.EVar v]
mkDecrFun _ (RVar _ _)
  = EVar
mkDecrFun _ _
  = panic Nothing "RefType.mkDecrFun called on invalid input"

-- | [NOTE]: THIS IS WHERE THE TERMINATION METRIC REFINEMENTS ARE CREATED.
cmpLexRef :: [(t1, t1, t1 -> Expr)] -> (t, t, t -> Expr) -> Expr
cmpLexRef vxs (v, x, g)
  = pAnd $  (PAtom Lt (g x) (g v)) : (PAtom Ge (g x) zero)
         :  [PAtom Eq (f y) (f z) | (y, z, f) <- vxs]
         ++ [PAtom Ge (f y) zero  | (y, _, f) <- vxs]
  where zero = ECon $ I 0

makeLexRefa :: [Located Expr] -> [Located Expr] -> UReft Reft
makeLexRefa es' es = uTop $ Reft (vv, PIff (EVar vv) $ pOr rs)
  where
    rs = makeLexReft [] [] (val <$> es) (val <$> es')
    vv = "vvRec"

makeLexReft :: [(Expr, Expr)] -> [Expr] -> [Expr] -> [Expr] -> [Expr]
makeLexReft _ acc [] []
  = acc
makeLexReft old acc (e:es) (e':es')
  = makeLexReft ((e,e'):old) (r:acc) es es'
  where
    r    = pAnd $  (PAtom Lt e' e)
                :  (PAtom Ge e' zero)
                :  [PAtom Eq o' o    | (o,o') <- old]
                ++ [PAtom Ge o' zero | (_,o') <- old]
    zero = ECon $ I 0
makeLexReft _ _ _ _
  = panic Nothing "RefType.makeLexReft on invalid input"

--------------------------------------------------------------------------------
mkTyConInfo :: TyCon -> VarianceInfo -> VarianceInfo -> Maybe SizeFun -> TyConInfo
mkTyConInfo c userTv userPv f = TyConInfo tcTv userPv f
  where
    tcTv                      = if null userTv then defTv else userTv
    defTv                     = makeTyConVariance c


makeTyConVariance :: TyCon -> VarianceInfo
makeTyConVariance c = varSignToVariance <$> tvs
  where
    tvs = GM.tyConTyVarsDef c

    varsigns = if TC.isTypeSynonymTyCon c
                  then go True (fromJust $ TC.synTyConRhs_maybe c)
                  else L.nub $ concatMap goDCon $ TC.tyConDataCons c

    varSignToVariance v = case filter (\p -> GM.showPpr (fst p) == GM.showPpr v) varsigns of
                            []       -> Invariant
                            [(_, b)] -> if b then Covariant else Contravariant
                            _        -> Bivariant


    goDCon dc = concatMap (go True) (DataCon.dataConOrigArgTys dc)

    go pos (FunTy t1 t2)   = go (not pos) t1 ++ go pos t2
    go pos (ForAllTy _ t)  = go pos t
    go pos (TyVarTy v)     = [(v, pos)]
    go pos (AppTy t1 t2)   = go pos t1 ++ go pos t2
    go pos (TyConApp c' ts)
       | c == c'
       = []

-- NV fix that: what happens if we have mutually recursive data types?
-- now just provide "default" Bivariant for mutually rec types.
-- but there should be a finer solution
       | mutuallyRecursive c c'
       = concat $ zipWith (goTyConApp pos) (repeat Bivariant) ts
       | otherwise
       = concat $ zipWith (goTyConApp pos) (makeTyConVariance c') ts

    go _   (LitTy _)       = []
    go _   (CoercionTy _)  = []
    go pos (CastTy t _)    = go pos t

    goTyConApp _   Invariant     _ = []
    goTyConApp pos Bivariant     t = goTyConApp pos Contravariant t ++ goTyConApp pos Covariant t
    goTyConApp pos Covariant     t = go pos       t
    goTyConApp pos Contravariant t = go (not pos) t

    mutuallyRecursive c c' = c `S.member` (dataConsOfTyCon c')


dataConsOfTyCon :: TyCon -> S.HashSet TyCon
dataConsOfTyCon = dcs S.empty
  where
    dcs vis c               = mconcat $ go vis <$> [t | dc <- TC.tyConDataCons c, t <- DataCon.dataConOrigArgTys dc]
    go  vis (FunTy t1 t2)   = go vis t1 `S.union` go vis t2
    go  vis (ForAllTy _ t)  = go vis t
    go  _   (TyVarTy _)     = S.empty
    go  vis (AppTy t1 t2)   = go vis t1 `S.union` go vis t2
    go  vis (TyConApp c ts)
      | c `S.member` vis
      = S.empty
      | otherwise
      = (S.insert c $ mconcat $ go vis <$> ts) `S.union` dcs (S.insert c vis) c
    go  _   (LitTy _)       = S.empty
    go  _   (CoercionTy _)  = S.empty
    go  vis (CastTy t _)    = go vis t

--------------------------------------------------------------------------------
-- | Printing Refinement Types -------------------------------------------------
--------------------------------------------------------------------------------

instance Show RTyVar where
  show = showpp

instance PPrint (UReft r) => Show (UReft r) where
  show = showpp

instance PPrint DataDecl where
  pprintTidy k dd = "data" <+> pprint (tycName dd) <+> ppMbSizeFun (tycSFun dd) <+> pprint (tycTyVars dd) <+> "="
                    $+$ nest 4 (vcat $ [ "|" <+> pprintTidy k c | c <- tycDCons dd ])

instance PPrint DataCtor where
  pprintTidy k (DataCtor c _   xts Nothing)  = pprintTidy k c <+> braces (ppFields k ", " xts)
  pprintTidy k (DataCtor c ths xts (Just t)) = pprintTidy k c <+> dcolon <+> ppThetas ths <+> (ppFields k "->" xts) <+> "->" <+> pprintTidy k t
    where
      ppThetas [] = empty
      ppThetas ts = parens (hcat $ punctuate ", " (pprintTidy k <$> ts)) <+> "=>"


ppFields :: (PPrint k, PPrint v) => Tidy -> Doc -> [(k, v)] -> Doc
ppFields k sep kvs = hcat $ punctuate sep (F.pprintTidy k <$> kvs)

ppMbSizeFun :: Maybe SizeFun -> Doc
ppMbSizeFun Nothing  = ""
ppMbSizeFun (Just z) = F.pprint z

-- instance PPrint DataCtor where
  -- pprintTidy k (DataCtor c xts t) =
    -- pprintTidy k c <+> text "::" <+> (hsep $ punctuate (text "->")
                                          -- ((pprintTidy k <$> xts) ++ [pprintTidy k t]))

-- ppHack :: (?callStack :: CallStack) => a -> b
-- ppHack _ = errorstar "OOPS"

instance PPrint (RType c tv r) => Show (RType c tv r) where
  show = showpp

instance PPrint (RTProp c tv r) => Show (RTProp c tv r) where
  show = showpp

instance PPrint REnv where
  pprintTidy k re = "RENV" $+$ pprintTidy k (reLocal re)
