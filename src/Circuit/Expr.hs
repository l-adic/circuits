{-# LANGUAGE StandaloneDeriving #-}

module Circuit.Expr
  ( UnOp (..),
    BinOp (..),
    Val (..),
    Var (..),
    Expr (..),
    ExprM,
    BuilderState (..),
    compile,
    emit,
    imm,
    addVar,
    addWire,
    freshPublicInput,
    freshPrivateInput,
    freshOutput,
    rotateList,
    runCircuitBuilder,
    evalCircuitBuilder,
    execCircuitBuilder,
    exprToArithCircuit,
    evalExpr,
    truncRotate,
  )
where

import Circuit.Affine
import Circuit.Arithmetic
import Data.Field.Galois (PrimeField)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Protolude
import Text.PrettyPrint.Leijen.Text hiding ((<$>))

data UnOp f a where
  UNeg :: UnOp f f
  UNot :: UnOp f Bool

-- \| # truncate bits, # rotate bits

data BinOp f a where
  BAdd :: BinOp f f
  BSub :: BinOp f f
  BMul :: BinOp f f
  BAnd :: BinOp f Bool
  BOr :: BinOp f Bool
  BXor :: BinOp f Bool

opPrecedence :: BinOp f a -> Int
opPrecedence BOr = 5
opPrecedence BXor = 5
opPrecedence BAnd = 5
opPrecedence BSub = 6
opPrecedence BAdd = 6
opPrecedence BMul = 7

data Val f ty where
  VField :: f -> Val f f
  VBool :: f -> Val f Bool
  VUnit :: Val f ()

deriving instance (Show f) => Show (Val f ty)

instance (Pretty f) => Pretty (Val f ty) where
  pretty (VField f) = pretty f
  pretty (VBool b) = pretty b
  pretty VUnit = "()"

data Var i f ty where
  VarField :: i -> Var i f f
  VarBool :: i -> Var i f Bool

deriving instance (Show i, Show f) => Show (Var i f ty)

instance (Pretty i) => Pretty (Var i f ty) where
  pretty (VarField f) = pretty f
  pretty (VarBool b) = pretty b

-- | Expression data type of (arithmetic) expressions over a field @f@
-- with variable names/indices coming from @i@.
data Expr i f ty where
  EVal :: Val f ty -> Expr i f ty
  EVar :: Var i f ty -> Expr i f ty
  EUnOp :: UnOp f ty -> Expr i f ty -> Expr i f ty
  EBinOp :: BinOp f ty -> Expr i f ty -> Expr i f ty -> Expr i f ty
  EIf :: Expr i f Bool -> Expr i f ty -> Expr i f ty -> Expr i f ty
  EEq :: Expr i f f -> Expr i f f -> Expr i f Bool

deriving instance (Show i, Show f) => Show (Expr i f ty)

deriving instance (Show f) => Show (BinOp f a)

deriving instance (Show f) => Show (UnOp f a)

instance Pretty (BinOp f a) where
  pretty op = case op of
    BAdd -> text "+"
    BSub -> text "-"
    BMul -> text "*"
    BAnd -> text "&&"
    BOr -> text "||"
    BXor -> text "xor"

instance Pretty (UnOp f a) where
  pretty op = case op of
    UNeg -> text "neg"
    UNot -> text "!"

instance (Pretty f, Pretty i, Pretty ty) => Pretty (Expr i f ty) where
  pretty = prettyPrec 0
    where
      prettyPrec :: Int -> Expr i f ty -> Doc
      prettyPrec p e =
        case e of
          EVal v ->
            pretty v
          EVar v ->
            pretty v
          -- TODO correct precedence
          EUnOp op e1 -> parens (pretty op <+> pretty e1)
          EBinOp op e1 e2 ->
            parensPrec (opPrecedence op) p $
              prettyPrec (opPrecedence op) e1
                <+> pretty op
                <+> prettyPrec (opPrecedence op) e2
          EIf b true false ->
            parensPrec 4 p (text "if" <+> pretty b <+> text "then" <+> pretty true <+> text "else" <+> pretty false)
          -- TODO correct precedence
          EEq l r ->
            parensPrec 1 p (pretty l) <+> text "=" <+> parensPrec 1 p (pretty r)

parensPrec :: Int -> Int -> Doc -> Doc
parensPrec opPrec p = if p > opPrec then parens else identity

-------------------------------------------------------------------------------
-- Evaluator
-------------------------------------------------------------------------------

-- | Truncate a number to the given number of bits and perform a right
-- rotation (assuming small-endianness) within the truncation.
truncRotate ::
  (Bits f) =>
  -- | number of bits to truncate to
  Int ->
  -- | number of bits to rotate by
  Int ->
  f ->
  f
truncRotate nbits nrots x =
  foldr
    ( \ix rest ->
        if testBit x ix
          then setBit rest ((ix + nrots) `mod` nbits)
          else rest
    )
    zeroBits
    [0 .. nbits - 1]

-- | Evaluate arithmetic expressions directly, given an environment
evalExpr ::
  (PrimeField f, Show i) =>
  -- | variable lookup
  (i -> vars -> Maybe f) ->
  -- | expression to evaluate
  Expr i f ty ->
  -- | input values
  vars ->
  -- | resulting value
  ty
evalExpr lookupVar expr vars = case expr of
  EVal v -> case v of
    VBool b -> b == 1
    VField f -> f
    VUnit -> ()
  EVar var -> case var of
    VarField i -> case lookupVar i vars of
      Just v -> v
      Nothing -> panic $ "TODO: incorrect var lookup: " <> show i
    VarBool i -> case lookupVar i vars of
      Just v -> v == 1
      Nothing -> panic $ "TODO: incorrect var lookup: " <> show i
  EUnOp UNeg e1 ->
    negate $ evalExpr lookupVar e1 vars
  EUnOp UNot e1 ->
    not $ evalExpr lookupVar e1 vars
  EBinOp op e1 e2 ->
    (evalExpr lookupVar e1 vars) `apply` (evalExpr lookupVar e2 vars)
    where
      apply = case op of
        BAdd -> (+)
        BSub -> (-)
        BMul -> (*)
        BAnd -> (&&)
        BOr -> (||)
        BXor -> \x y -> (x || y) && not (x && y)
  EIf b true false ->
    if evalExpr lookupVar b vars
      then evalExpr lookupVar true vars
      else evalExpr lookupVar false vars
  EEq lhs rhs -> evalExpr lookupVar lhs vars == evalExpr lookupVar rhs vars

-------------------------------------------------------------------------------
-- Circuit Builder
-------------------------------------------------------------------------------

data BuilderState f = BuilderState
  { bsCircuit :: ArithCircuit f,
    bsNextVar :: Int,
    bsVars :: CircuitVars Text
  }

defaultBuilderState :: BuilderState f
defaultBuilderState =
  BuilderState
    { bsCircuit = ArithCircuit [],
      bsNextVar = 1,
      bsVars = mempty
    }

type ExprM f a = State (BuilderState f) a

execCircuitBuilder :: ExprM f a -> ArithCircuit f
execCircuitBuilder m = reverseCircuit $ bsCircuit $ execState m defaultBuilderState
  where
    reverseCircuit = \(ArithCircuit cs) -> ArithCircuit $ reverse cs

evalCircuitBuilder :: ExprM f a -> a
evalCircuitBuilder = fst . runCircuitBuilder

runCircuitBuilder :: ExprM f a -> (a, BuilderState f)
runCircuitBuilder m =
  let (a, s) = runState m defaultBuilderState
   in ( a,
        s
          { bsCircuit = reverseCircuit $ bsCircuit s
          }
      )
  where
    reverseCircuit = \(ArithCircuit cs) -> ArithCircuit $ reverse cs

fresh :: ExprM f Int
fresh = do
  v <- gets bsNextVar
  modify $ \s ->
    s
      { bsVars = (bsVars s) {cvVars = Set.insert v (cvVars $ bsVars s)},
        bsNextVar = v + 1
      }
  pure v

-- | Fresh intermediate variables
imm :: ExprM f Wire
imm = IntermediateWire <$> fresh

-- | Fresh input variables
freshPublicInput :: Text -> ExprM f Wire
freshPublicInput label = do
  v <- InputWire label Public <$> fresh
  modify $ \s ->
    s
      { bsVars =
          (bsVars s)
            { cvPublicInputs = Set.insert (wireName v) (cvPublicInputs $ bsVars s),
              cvInputsLabels = Map.insert label (wireName v) (cvInputsLabels $ bsVars s)
            }
      }
  pure v

freshPrivateInput :: Text -> ExprM f Wire
freshPrivateInput label = do
  v <- InputWire label Private <$> fresh
  modify $ \s ->
    s
      { bsVars =
          (bsVars s)
            { cvPrivateInputs = Set.insert (wireName v) (cvPrivateInputs $ bsVars s),
              cvInputsLabels = Map.insert label (wireName v) (cvInputsLabels $ bsVars s)
            }
      }
  pure v

-- | Fresh output variables
freshOutput :: ExprM f Wire
freshOutput = do
  v <- OutputWire <$> fresh
  modify $ \s ->
    s
      { bsVars =
          (bsVars s)
            { cvOutputs = Set.insert (wireName v) (cvOutputs $ bsVars s)
            }
      }
  pure v

-- | Multiply two wires or affine circuits to an intermediate variable
mulToImm :: Either Wire (AffineCircuit f Wire) -> Either Wire (AffineCircuit f Wire) -> ExprM f Wire
mulToImm l r = do
  o <- imm
  emit $ Mul (addVar l) (addVar r) o
  pure o

-- | Add a Mul and its output to the ArithCircuit
emit :: Gate f Wire -> ExprM f ()
emit c = modify $ \s@(BuilderState {bsCircuit = ArithCircuit cs}) ->
  s {bsCircuit = ArithCircuit (c : cs)}

-- | Rotate a list to the right
rotateList :: Int -> [a] -> [a]
rotateList steps x = take (length x) $ drop steps $ cycle x

-- | Turn a wire into an affine circuit, or leave it be
addVar :: Either Wire (AffineCircuit f Wire) -> AffineCircuit f Wire
addVar (Left w) = Var w
addVar (Right c) = c

-- | Turn an affine circuit into a wire, or leave it be
addWire :: (Num f) => Either Wire (AffineCircuit f Wire) -> ExprM f Wire
addWire (Left w) = pure w
addWire (Right c) = do
  mulOut <- imm
  emit $ Mul (ConstGate 1) c mulOut
  pure mulOut

compile :: (Num f) => Expr Wire f ty -> ExprM f (Either Wire (AffineCircuit f Wire))
compile expr = case expr of
  EVal v -> case v of
    VField f -> pure . Right $ ConstGate f
    VBool b -> pure . Right $ ConstGate b
    VUnit -> pure . Right $ Nil
  EVar var -> case var of
    VarField i -> pure . Left $ i
    VarBool i -> pure . Left $ i
  EUnOp op e1 -> do
    e1Out <- compile e1
    case op of
      UNeg -> pure . Right $ ScalarMul (-1) (addVar e1Out)
      UNot -> pure . Right $ Add (ConstGate 1) (ScalarMul (-1) (addVar e1Out))
  EBinOp op e1 e2 -> do
    e1Out <- addVar <$> compile e1
    e2Out <- addVar <$> compile e2
    case op of
      BAdd -> pure . Right $ Add e1Out e2Out
      BMul -> do
        tmp1 <- mulToImm (Right e1Out) (Right e2Out)
        pure . Left $ tmp1
      -- SUB(x, y) = x + (-y)
      BSub -> pure . Right $ Add e1Out (ScalarMul (-1) e2Out)
      BAnd -> do
        tmp1 <- mulToImm (Right e1Out) (Right e2Out)
        pure . Left $ tmp1
      BOr -> do
        -- OR(input1, input2) = (input1 + input2) - (input1 * input2)
        tmp1 <- imm
        emit $ Mul e1Out e2Out tmp1
        pure . Right $ Add (Add e1Out e2Out) (ScalarMul (-1) (Var tmp1))
      BXor -> do
        -- XOR(input1, input2) = (input1 + input2) - 2 * (input1 * input2)
        tmp1 <- imm
        emit $ Mul e1Out e2Out tmp1
        pure . Right $ Add (Add e1Out e2Out) (ScalarMul (-2) (Var tmp1))
  -- IF(cond, true, false) = (cond*true) + ((!cond) * false)
  EIf cond true false -> do
    condOut <- addVar <$> compile cond
    trueOut <- addVar <$> compile true
    falseOut <- addVar <$> compile false
    tmp1 <- imm
    tmp2 <- imm
    emit $ Mul condOut trueOut tmp1
    emit $ Mul (Add (ConstGate 1) (ScalarMul (-1) condOut)) falseOut tmp2
    pure . Right $ Add (Var tmp1) (Var tmp2)
  -- EQ(lhs, rhs) = (lhs - rhs == 1)
  EEq lhs rhs -> do
    lhsSubRhs <- compile (EBinOp BSub lhs rhs)
    eqInWire <- addWire lhsSubRhs
    eqFreeWire <- imm
    eqOutWire <- imm
    emit $ Equal eqInWire eqFreeWire eqOutWire
    -- eqOutWire == 0 if lhs == rhs, so we need to return 1 -
    -- neqOutWire instead.
    pure . Right $ Add (ConstGate 1) (ScalarMul (-1) (Var eqOutWire))

-- | Translate an arithmetic expression to an arithmetic circuit
exprToArithCircuit ::
  (Num f) =>
  -- | expression to compile
  Expr Int f ty ->
  -- | Wire to assign the output of the expression to
  Wire ->
  ExprM f ()
exprToArithCircuit expr output =
  exprToArithCircuit' (mapVarsExpr (InputWire "" Public) expr) output

exprToArithCircuit' :: (Num f) => Expr Wire f ty -> Wire -> ExprM f ()
exprToArithCircuit' expr output = do
  exprOut <- compile expr
  emit $ Mul (ConstGate 1) (addVar exprOut) output

-- | Apply function to variable names.
mapVarsExpr :: (i -> j) -> Expr i f ty -> Expr j f ty
mapVarsExpr f expr = case expr of
  EVar var -> case var of
    VarBool i -> EVar $ VarBool $ f i
    VarField i -> EVar $ VarField $ f i
  EVal v -> EVal v
  EBinOp op e1 e2 -> EBinOp op (mapVarsExpr f e1) (mapVarsExpr f e2)
  EUnOp op e1 -> EUnOp op (mapVarsExpr f e1)
  EIf b tr fl -> EIf (mapVarsExpr f b) (mapVarsExpr f tr) (mapVarsExpr f fl)
  EEq lhs rhs -> EEq (mapVarsExpr f lhs) (mapVarsExpr f rhs)
