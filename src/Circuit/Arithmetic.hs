-- | Definition of arithmetic circuits: one with a single
-- multiplication gate with affine inputs and another variant with an
-- arbitrary number of such gates.
module Circuit.Arithmetic
  ( Gate (..),
    outputWires,
    ArithCircuit (..),
    validArithCircuit,
    Wire (..),
    InputType (..),
    wireName,
    evalGate,
    evalArithCircuit,
    unsplit,
    relabel,
    collectVariables,
  )
where

import Circuit.Affine
  ( AffineCircuit (..),
    evalAffineCircuit,
  )
import Data.Aeson (FromJSON, ToJSON)
import Data.Field.Galois (PrimeField, fromP)
import Data.Set qualified as Set
import Protolude
import Text.PrettyPrint.Leijen.Text as PP
  ( Pretty (..),
    hsep,
    list,
    parens,
    text,
    vcat,
  )

data InputType = Public | Private deriving (Show, Eq, Ord, Generic, NFData)

instance FromJSON InputType

instance ToJSON InputType

-- | Wires are can be labeled in the ways given in this data type
data Wire
  = InputWire InputType Int
  | IntermediateWire Int
  | OutputWire Int
  deriving (Show, Eq, Ord, Generic, NFData)

instance FromJSON Wire

instance ToJSON Wire

instance Pretty Wire where
  pretty (InputWire t v) =
    let a = case t of
          Public -> "pub"
          Private -> "priv"
     in text (a <> "_input_") <> pretty v
  pretty (IntermediateWire v) = text "imm_" <> pretty v
  pretty (OutputWire v) = text "output_" <> pretty v

wireName :: Wire -> Int
wireName (InputWire _ v) = v
wireName (IntermediateWire v) = v
wireName (OutputWire v) = v

-- | An arithmetic circuit with a single multiplication gate.
data Gate f i
  = Mul
      { mulLeft :: AffineCircuit f i,
        mulRight :: AffineCircuit f i,
        mulOutput :: i
      }
  | Equal
      { eqInput :: i,
        eqMagic :: i,
        eqOutput :: i
      }
  | Split
      { splitInput :: i,
        splitOutputs :: [i]
      }
  deriving (Show, Eq, Ord, Generic, NFData, FromJSON, ToJSON)

deriving instance Functor (Gate f)

deriving instance Foldable (Gate f)

deriving instance Traversable (Gate f)

instance Bifunctor Gate where
  bimap f g = \case
    Mul l r o -> Mul (bimap f g l) (bimap f g r) (g o)
    Equal i m o -> Equal (g i) (g m) (g o)
    Split i os -> Split (g i) (map g os)

-- | List output wires of a gate
outputWires :: Gate f i -> [i]
outputWires = \case
  Mul _ _ out -> [out]
  Equal _ _ out -> [out]
  Split _ outs -> outs

instance (Pretty i, Show f) => Pretty (Gate f i) where
  pretty (Mul l r o) =
    hsep
      [ pretty o,
        text ":=",
        parens (pretty l),
        text "*",
        parens (pretty r)
      ]
  pretty (Equal i _ o) =
    hsep
      [ pretty o,
        text ":=",
        pretty i,
        text "== 0 ? 0 : 1"
      ]
  pretty (Split inp outputs) =
    hsep
      [ PP.list (map pretty outputs),
        text ":=",
        text "split",
        pretty inp
      ]

-- | Evaluate a single gate
evalGate ::
  (PrimeField f) =>
  -- | lookup a value at a wire
  (i -> vars -> Maybe f) ->
  -- | update a value at a wire
  (i -> f -> vars -> vars) ->
  -- | context before evaluation
  vars ->
  -- | gate
  Gate f i ->
  -- | context after evaluation
  vars
evalGate lookupVar updateVar vars gate =
  case gate of
    Mul l r outputWire ->
      let lval = evalAffineCircuit lookupVar vars l
          rval = evalAffineCircuit lookupVar vars r
          res = lval * rval
       in updateVar outputWire res vars
    Equal i m outputWire ->
      case lookupVar i vars of
        Nothing ->
          panic "evalGate: the impossible happened"
        Just inp ->
          let res = if inp == 0 then 0 else 1
              mid = if inp == 0 then 0 else recip inp
           in updateVar outputWire res $
                updateVar m mid vars
    Split i os ->
      case lookupVar i vars of
        Nothing ->
          panic "evalGate: the impossible happened"
        Just inp ->
          let bool2val True = 1
              bool2val False = 0
              setWire (ix, oldEnv) currentOut =
                ( ix + 1,
                  updateVar currentOut (bool2val $ testBit (fromP inp) ix) oldEnv
                )
           in snd . foldl setWire (0, vars) $ os

-- | A circuit is a list of multiplication gates along with their
-- output wire labels (which can be intermediate or actual outputs).
newtype ArithCircuit f = ArithCircuit [Gate f Wire]
  deriving (Eq, Show, Generic)
  deriving (NFData) via ([Gate f Wire])

instance (FromJSON f) => FromJSON (ArithCircuit f)

instance (ToJSON f) => ToJSON (ArithCircuit f)

instance Functor ArithCircuit where
  fmap f (ArithCircuit gates) = ArithCircuit $ map (first f) gates

instance (Show f) => Pretty (ArithCircuit f) where
  pretty (ArithCircuit gs) = vcat . map pretty $ gs

-- | Check whether an arithmetic circuit does not refer to
-- intermediate wires before they are defined and whether output wires
-- are not used as input wires.
validArithCircuit ::
  ArithCircuit f -> Bool
validArithCircuit (ArithCircuit gates) =
  noRefsToUndefinedWires
  where
    noRefsToUndefinedWires =
      fst $
        foldl
          ( \(res, definedWires) gate ->
              ( res
                  && all isNotInput (outputWires gate)
                  && all (validWire definedWires) (fetchVarsGate gate),
                outputWires gate ++ definedWires
              )
          )
          (True, [])
          gates
    isNotInput (InputWire _ _) = False
    isNotInput (OutputWire _) = True
    isNotInput (IntermediateWire _) = True
    validWire _ (InputWire _ _) = True
    validWire _ (OutputWire _) = False
    validWire definedWires i@(IntermediateWire _) = i `elem` definedWires
    fetchVarsGate (Mul l r _) = toList l <> toList r
    fetchVarsGate (Equal i _ _) = [i] -- we can ignore the magic
    -- variable "m", as it is filled
    -- in when evaluating the circuit
    fetchVarsGate (Split i _) = [i]

-- | Evaluate an arithmetic circuit on a given environment containing
-- the inputs. Outputs the entire environment (outputs, intermediate
-- values and inputs).
evalArithCircuit ::
  forall f vars.
  (PrimeField f) =>
  -- | lookup a value at a wire
  (Wire -> vars -> Maybe f) ->
  -- | update a value at a wire
  (Wire -> f -> vars -> vars) ->
  -- | circuit to evaluate
  ArithCircuit f ->
  -- | input variables
  vars ->
  -- | input and output variables
  vars
evalArithCircuit lookupVar updateVar (ArithCircuit gates) vars =
  foldl' (evalGate lookupVar updateVar) vars gates

-- | Turn a binary expansion back into a single value.
unsplit ::
  (Num f) =>
  -- | (binary) wires containing a binary expansion,
  -- small-endian
  [Wire] ->
  AffineCircuit f Wire
unsplit = snd . foldl (\(ix, rest) wire -> (ix + (1 :: Integer), Add rest (ScalarMul (2 ^ ix) (Var wire)))) (0, ConstGate 0)

relabel :: (Int -> Int) -> ArithCircuit f -> ArithCircuit f
relabel f (ArithCircuit gates) = ArithCircuit $ map (second $ mapWire f) gates
  where
    mapWire g (InputWire t v) = InputWire t (g v)
    mapWire g (IntermediateWire v) = IntermediateWire (g v)
    mapWire g (OutputWire v) = OutputWire (g v)

collectVariables :: ArithCircuit f -> Set Int
collectVariables (ArithCircuit gates) = foldMap (foldMap $ Set.singleton . wireName) gates