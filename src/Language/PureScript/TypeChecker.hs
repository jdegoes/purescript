-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.TypeChecker
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
-- The top-level type checker, which checks all declarations in a module.
--
-----------------------------------------------------------------------------

{-# LANGUAGE FlexibleInstances #-}

module Language.PureScript.TypeChecker (
    module T,
    typeCheckAll
) where

import Language.PureScript.TypeChecker.Monad as T
import Language.PureScript.TypeChecker.Kinds as T
import Language.PureScript.TypeChecker.Types as T
import Language.PureScript.TypeChecker.Synonyms as T

import Data.Maybe
import Data.List (nub, (\\))
import Data.Monoid ((<>))
import Data.Foldable (for_)
import qualified Data.Map as M

import Control.Monad.State
import Control.Monad.Error

import Language.PureScript.Types
import Language.PureScript.Names
import Language.PureScript.Kinds
import Language.PureScript.Declarations
import Language.PureScript.TypeClassDictionaries
import Language.PureScript.Environment
import Language.PureScript.Errors

addDataType :: ModuleName -> DataDeclType -> ProperName -> [String] -> [(ProperName, [Type])] -> Kind -> Check ()
addDataType moduleName dtype name args dctors ctorKind = do
  env <- getEnv
  putEnv $ env { types = M.insert (Qualified (Just moduleName) name) (ctorKind, DataType args dctors) (types env) }
  forM_ dctors $ \(dctor, tys) ->
    rethrow (strMsg ("Error in data constructor " ++ show dctor) <>) $
      addDataConstructor moduleName dtype name args dctor tys

addDataConstructor :: ModuleName -> DataDeclType -> ProperName -> [String] -> ProperName -> [Type] -> Check ()
addDataConstructor moduleName dtype name args dctor tys = do
  env <- getEnv
  let retTy = foldl TypeApp (TypeConstructor (Qualified (Just moduleName) name)) (map TypeVar args)
  let dctorTy = foldr function retTy tys
  let polyType = mkForAll args dctorTy
  putEnv $ env { dataConstructors = M.insert (Qualified (Just moduleName) dctor) (dtype, name, polyType) (dataConstructors env) }

addTypeSynonym :: ModuleName -> ProperName -> [String] -> Type -> Kind -> Check ()
addTypeSynonym moduleName name args ty kind = do
  env <- getEnv
  putEnv $ env { types = M.insert (Qualified (Just moduleName) name) (kind, TypeSynonym) (types env)
               , typeSynonyms = M.insert (Qualified (Just moduleName) name) (args, ty) (typeSynonyms env) }

valueIsNotDefined :: ModuleName -> Ident -> Check ()
valueIsNotDefined moduleName name = do
  env <- getEnv
  case M.lookup (moduleName, name) (names env) of
    Just _ -> throwError . strMsg $ show name ++ " is already defined"
    Nothing -> return ()

addValue :: ModuleName -> Ident -> Type -> NameKind -> Check ()
addValue moduleName name ty nameKind = do
  env <- getEnv
  putEnv (env { names = M.insert (moduleName, name) (ty, nameKind, Defined) (names env) })

addTypeClass :: ModuleName -> ProperName -> [String] -> [(Qualified ProperName, [Type])] -> [Declaration] -> Check ()
addTypeClass moduleName pn args implies ds =
  let members = map toPair ds in
  modify $ \st -> st { checkEnv = (checkEnv st) { typeClasses = M.insert (Qualified (Just moduleName) pn) (args, members, implies) (typeClasses . checkEnv $ st) } }
  where
  toPair (TypeDeclaration ident ty) = (ident, ty)
  toPair (PositionedDeclaration _ d) = toPair d
  toPair _ = error "Invalid declaration in TypeClassDeclaration"

addTypeClassDictionaries :: [TypeClassDictionaryInScope] -> Check ()
addTypeClassDictionaries entries =
  let mentries = M.fromList [ ((canonicalizeDictionary entry, mn), entry) | entry@TypeClassDictionaryInScope{ tcdName = Qualified mn _ }  <- entries ]
  in modify $ \st -> st { checkEnv = (checkEnv st) { typeClassDictionaries = (typeClassDictionaries . checkEnv $ st) `M.union` mentries } }

checkDuplicateTypeArguments :: [String] -> Check ()
checkDuplicateTypeArguments args = for_ firstDup $ \dup ->
  throwError . strMsg $ "Duplicate type argument '" ++ dup ++ "'"
  where
  firstDup :: Maybe String
  firstDup = listToMaybe $ args \\ nub args

checkTypeClassInstance :: ModuleName -> Type -> Check ()
checkTypeClassInstance _ (TypeVar _) = return ()
checkTypeClassInstance _ (TypeConstructor ctor) = do
  env <- getEnv
  when (ctor `M.member` typeSynonyms env) . throwError . strMsg $ "Type synonym instances are disallowed"
  return ()
checkTypeClassInstance m (TypeApp t1 t2) = checkTypeClassInstance m t1 >> checkTypeClassInstance m t2
checkTypeClassInstance _ ty = throwError $ mkErrorStack "Type class instance head is invalid." (Just (TypeError ty))

-- |
-- Type check all declarations in a module
--
-- At this point, many declarations will have been desugared, but it is still necessary to
--
--  * Kind-check all types and add them to the @Environment@
--
--  * Type-check all values and add them to the @Environment@
--
--  * Bring type class instances into scope
--
--  * Process module imports
--
typeCheckAll :: Maybe ModuleName -> ModuleName -> Maybe [DeclarationRef] -> [Declaration] -> Check [Declaration]
typeCheckAll mainModuleName moduleName exps = go
  where
  go :: [Declaration] -> Check [Declaration]
  go [] = return []
  go (d@(DataDeclaration dtype name args dctors) : rest) = do
    rethrow (strMsg ("Error in type constructor " ++ show name) <>) $ do
      when (dtype == Newtype) $ checkNewtype dctors
      checkDuplicateTypeArguments args
      ctorKind <- kindsOf True moduleName name args (concatMap snd dctors)
      addDataType moduleName dtype name args dctors ctorKind
    ds <- go rest
    return $ d : ds
    where
    checkNewtype :: [(ProperName, [Type])] -> Check ()
    checkNewtype [(_, [_])] = return ()
    checkNewtype [(_, _)] = throwError . strMsg $ "newtypes constructors must have a single argument"
    checkNewtype _ = throwError . strMsg $ "newtypes must have a single constructor"
  go (d@(DataBindingGroupDeclaration tys) : rest) = do
    rethrow (strMsg "Error in data binding group" <>) $ do
      let syns = mapMaybe toTypeSynonym tys
      let dataDecls = mapMaybe toDataDecl tys
      (syn_ks, data_ks) <- kindsOfAll moduleName syns (map (\(_, name, args, dctors) -> (name, args, concatMap snd dctors)) dataDecls)
      forM_ (zip dataDecls data_ks) $ \((dtype, name, args, dctors), ctorKind) -> do
        checkDuplicateTypeArguments args
        addDataType moduleName dtype name args dctors ctorKind
      forM_ (zip syns syn_ks) $ \((name, args, ty), kind) -> do
        checkDuplicateTypeArguments args
        addTypeSynonym moduleName name args ty kind
    ds <- go rest
    return $ d : ds
    where
    toTypeSynonym (TypeSynonymDeclaration nm args ty) = Just (nm, args, ty)
    toTypeSynonym (PositionedDeclaration _ d') = toTypeSynonym d'
    toTypeSynonym _ = Nothing
    toDataDecl (DataDeclaration dtype nm args dctors) = Just (dtype, nm, args, dctors)
    toDataDecl (PositionedDeclaration _ d') = toDataDecl d'
    toDataDecl _ = Nothing
  go (d@(TypeSynonymDeclaration name args ty) : rest) = do
    rethrow (strMsg ("Error in type synonym " ++ show name) <>) $ do
      checkDuplicateTypeArguments args
      kind <- kindsOf False moduleName name args [ty]
      addTypeSynonym moduleName name args ty kind
    ds <- go rest
    return $ d : ds
  go (TypeDeclaration _ _ : _) = error "Type declarations should have been removed"
  go (ValueDeclaration name nameKind [] Nothing val : rest) = do
    d <- rethrow (strMsg ("Error in declaration " ++ show name) <>) $ do
      valueIsNotDefined moduleName name
      [(_, (val', ty))] <- typesOf mainModuleName moduleName [(name, val)]
      addValue moduleName name ty nameKind
      return $ ValueDeclaration name nameKind [] Nothing val'
    ds <- go rest
    return $ d : ds
  go (ValueDeclaration{} : _) = error "Binders were not desugared"
  go (BindingGroupDeclaration vals : rest) = do
    d <- rethrow (strMsg ("Error in binding group " ++ show (map (\(ident, _, _) -> ident) vals)) <>) $ do
      forM_ (map (\(ident, _, _) -> ident) vals) $ \name ->
        valueIsNotDefined moduleName name
      tys <- typesOf mainModuleName moduleName $ map (\(ident, _, ty) -> (ident, ty)) vals
      vals' <- forM (zipWith (\(name, nameKind, _) (_, (val, ty)) -> (name, val, nameKind, ty)) vals tys) $ \(name, val, nameKind, ty) -> do
        addValue moduleName name ty nameKind
        return (name, nameKind, val)
      return $ BindingGroupDeclaration vals'
    ds <- go rest
    return $ d : ds
  go (d@(ExternDataDeclaration name kind) : rest) = do
    env <- getEnv
    putEnv $ env { types = M.insert (Qualified (Just moduleName) name) (kind, ExternData) (types env) }
    ds <- go rest
    return $ d : ds
  go (d@(ExternDeclaration importTy name _ ty) : rest) = do
    rethrow (strMsg ("Error in foreign import declaration " ++ show name) <>) $ do
      env <- getEnv
      kind <- kindOf moduleName ty
      guardWith (strMsg "Expected kind *") $ kind == Star
      case M.lookup (moduleName, name) (names env) of
        Just _ -> throwError . strMsg $ show name ++ " is already defined"
        Nothing -> putEnv (env { names = M.insert (moduleName, name) (ty, Extern importTy, Defined) (names env) })
    ds <- go rest
    return $ d : ds
  go (d@(FixityDeclaration _ name) : rest) = do
    ds <- go rest
    env <- getEnv
    guardWith (strMsg ("Fixity declaration with no binding: " ++ name)) $ M.member (moduleName, Op name) $ names env
    return $ d : ds
  go (d@(ImportDeclaration importedModule _ _) : rest) = do
    tcds <- getTypeClassDictionaries
    let instances = filter (\tcd -> let Qualified (Just mn) _ = tcdName tcd in importedModule == mn) tcds
    addTypeClassDictionaries [ tcd { tcdName = Qualified (Just moduleName) ident, tcdType = TCDAlias (canonicalizeDictionary tcd) }
                             | tcd <- instances
                             , tcdExported tcd
                             , let (Qualified _ ident) = tcdName tcd
                             ]
    ds <- go rest
    return $ d : ds
  go (d@(TypeClassDeclaration pn args implies tys) : rest) = do
    addTypeClass moduleName pn args implies tys
    ds <- go rest
    return $ d : ds
  go (TypeInstanceDeclaration dictName deps className tys _ : rest) = do
    go (ExternInstanceDeclaration dictName deps className tys : rest)
  go (d@(ExternInstanceDeclaration dictName deps className tys) : rest) = do
    mapM_ (checkTypeClassInstance moduleName) tys
    forM_ deps $ mapM_ (checkTypeClassInstance moduleName) . snd
    addTypeClassDictionaries [TypeClassDictionaryInScope (Qualified (Just moduleName) dictName) className tys (Just deps) TCDRegular isInstanceExported]
    ds <- go rest
    return $ d : ds
    where
    isInstanceExported :: Bool
    isInstanceExported = maybe True (any exportsInstance) exps 
    
    exportsInstance :: DeclarationRef -> Bool
    exportsInstance (TypeInstanceRef name) | name == dictName = True
    exportsInstance (PositionedDeclarationRef _ r) = exportsInstance r
    exportsInstance _ = False
    
  go (PositionedDeclaration pos d : rest) =
    rethrowWithPosition pos $ do
      (d' : rest') <- go (d : rest)
      return (PositionedDeclaration pos d' : rest')




