module Test.Circuit.Sudoku where

import Circuit
import Circuit.Language
import Data.Array.IO (IOArray, getElems, newArray, readArray, writeArray)
import Data.Distributive (Distributive (distribute))
import Data.Field.Galois (PrimeField)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.IntMap qualified as IntMap
import Data.List (union, (!!), (\\))
import Data.Map qualified as Map
import Data.Maybe (fromJust)
import Data.Type.Nat (Nat3, Nat9)
import Data.Type.Nat qualified as Nat
import Data.Vec.Lazy (Vec, universe)
import Data.Vec.Lazy qualified as Vec
import Data.Vector qualified as V
import Protolude hiding (head)
import Test.Hspec (Spec, describe, it, shouldBe)

type SudokuSet a = Vec Nat9 a

type Board a = Vec Nat9 (Vec Nat9 a)

type Box a = Vec Nat3 (Vec Nat3 a)

type BoxGrid a = Vec Nat3 (Vec Nat3 (Box a))

mkBoxes :: Board a -> BoxGrid a
mkBoxes = Vec.chunks @Nat3 . fmap (Vec.chunks @Nat3)

sudokuSet ::
  (Num f, Hashable f) =>
  SudokuSet (Signal f 'TField)
sudokuSet = Vec.tabulate (cField . (+ 1) . fromIntegral)

isPermutation ::
  forall f.
  (PrimeField f, Hashable f) =>
  [Signal f 'TField] ->
  [Signal f 'TField] ->
  Signal f 'TBool
isPermutation as bs =
  let f (a, i) =
        let isPresent = elem_ a bs
            isUnique = not_ $ elem_ a (take i as)
         in isPresent `and_` isUnique
   in all_ f (zip as [0 ..])

validateBoxes ::
  (PrimeField f, Hashable f) =>
  SudokuSet (Signal f 'TField) ->
  BoxGrid (Signal f 'TField) ->
  Signal f 'TBool
validateBoxes ss boxes =
  let f box = isPermutation (Vec.toList ss) (Vec.toList $ Vec.concat box)
   in all_ f $ Vec.concat boxes

mkBoard :: (Hashable f) => ExprM f (Board (Signal f 'TField))
mkBoard =
  for (universe @Nat9) $ \i ->
    for (universe @Nat9) $ \j -> do
      let varName = "cell_" <> show i <> show j
      var_ <$> fieldInput Public varName

initializeBoard ::
  (PrimeField f, Hashable f) =>
  Board (Signal f 'TField) ->
  ExprM f (Board (Signal f 'TField))
initializeBoard board = do
  for (universe @Nat9) $ \i ->
    for (universe @Nat9) $ \j -> do
      let cell = board Vec.! i Vec.! j
          varName = "private_cell_" <> show i <> show j
      v <- var_ <$> fieldInput Private varName
      pure $ if_ (cell `eq_` cField 0) v cell

validate :: ExprM BN128 (Signal BN128 'TBool)
validate = do
  b <- mkBoard >>= initializeBoard
  let rowsValid = all_ (isPermutation $ Vec.toList sudokuSet) (Vec.toList <$> b)
      colsValid = all_ (isPermutation $ Vec.toList sudokuSet) (Vec.toList <$> distribute b)
      boxesValid = validateBoxes sudokuSet (mkBoxes b)
  let res = rowsValid `and_` colsValid `and_` boxesValid
  void $ boolOutput "out" res
  pure res

--------------------------------------------------------------------------------
spec_sudokuSolver :: Spec
spec_sudokuSolver = do
  describe "Can solve example sudoku problems" $
    it "Matches the pure implementation" $ do
      for_ (zip [(0 :: Int) ..] examplePuzzles) $ \(i, b) -> do
        sol <- Map.toAscList <$> solvePuzzle (concat b)
        let pubAssignments =
              map (first (\a -> ("cell_" <> show (fst a) <> show (snd a), Nothing))) $
                [((_i, j), v) | _i <- [0 .. 8], j <- [0 .. 8], let v = b !! _i !! j]
            privAssignments =
              map (first (\a -> ("private_cell_" <> show (fst a) <> show (snd a), Nothing))) $
                filter (\(_, v) -> v /= 0) sol
            (prog, BuilderState {bsVars, bsCircuit}) = runCircuitBuilder validate
        let pubInputs =
              IntMap.fromList $
                [ (_var, fromIntegral value)
                  | (label, _var) <- Map.toList $ labelToVar $ cvInputsLabels bsVars,
                    (l, value) <- pubAssignments,
                    l == label
                ]
            privInputs =
              IntMap.fromList $
                [ (_var, fromIntegral value)
                  | (label, _var) <- Map.toList $ labelToVar $ cvInputsLabels bsVars,
                    (l, value) <- privAssignments,
                    l == label
                ]
            out = lookupVar bsVars "out" sol2
            sol2 = altSolve bsCircuit (pubInputs `IntMap.union` privInputs)
            computed = evalExpr IntMap.lookup (pubInputs `IntMap.union` privInputs) (relabelExpr wireName prog)
        verifier (map snd sol) `shouldBe` True
        (i, out) `shouldBe` (i, Just 1)
        (i, computed) `shouldBe` (i, Right $ V.singleton 1)

verifier :: [Int] -> Bool
verifier _input =
  let input :: Vec (Nat.FromGHC 81) Int
      input = fromJust $ Vec.fromList _input
      board = Vec.chunks @Nat9 input
      validRows = all (\row -> sort (Vec.toList row) == [1 .. 9]) board
      validCols = all (\col -> sort (Vec.toList col) == [1 .. 9]) (distribute board)
      boxes = mkBoxes board
      validBoxes = all (\box -> sort (Vec.toList $ Vec.concat box) == [1 .. 9]) (Vec.concat boxes)
   in validRows && validCols && validBoxes

--------------------------------------------------------------------------------

-- solver

solvePuzzle :: [Int] -> IO (Map.Map (Int, Int) Int)
solvePuzzle inputs =
  mkPuzzleMap <$> do
    ref <- newIORef []
    a <- newArray (1, 81) 0
    readSudokuBoard a inputs
    solveSudoku ref a (1, 1)
    readIORef ref
  where
    mkPuzzleMap :: [Int] -> Map.Map (Int, Int) Int
    mkPuzzleMap xs = Map.fromList $ zip [(x, y) | x <- [0 .. 8], y <- [0 .. 8]] xs

type SudokuBoard = IOArray Int Int

readSudokuBoard :: SudokuBoard -> [Int] -> IO ()
readSudokuBoard a xs = sequence_ $ do
  (i, n) <- zip [1 .. 81] xs
  return $ writeArray a i n

-- the meat of the program.  Checks the current square.
-- If 0, then get the list of nums and try to "solveSudoku' "
-- Otherwise, go to the next square.
solveSudoku :: IORef [Int] -> SudokuBoard -> (Int, Int) -> IO ()
solveSudoku ref a (10, y) = solveSudoku ref a (1, y + 1)
solveSudoku ref a (_, 10) = do
  writeIORef ref =<< getElems a
solveSudoku ref a (x, y) = do
  v <- readBoard a (x, y)
  case v of
    0 -> availableNums a (x, y) >>= solveSudoku' (x, y)
    _ -> solveSudoku ref a (x + 1, y)
  where
    -- solveSudoku' handles the backtacking
    solveSudoku' (_x, _y) [] = return ()
    solveSudoku' (_x, _y) (v : vs) = do
      writeBoard a (_x, _y) v -- put a guess onto the board
      solveSudoku ref a (_x + 1, _y)
      writeBoard a (_x, _y) 0 -- remove the guess from the board
      solveSudoku' (_x, _y) vs -- recurse over the remainder of the list

-- get the "taken" numbers from a row, col or box.
getRowNums :: SudokuBoard -> Int -> IO [Int]
getRowNums a y = sequence [readBoard a (x', y) | x' <- [1 .. 9]]

getColNums :: SudokuBoard -> Int -> IO [Int]
getColNums a x = sequence [readBoard a (x, y') | y' <- [1 .. 9]]

getBoxNums :: SudokuBoard -> (Int, Int) -> IO [Int]
getBoxNums a (x, y) = sequence [readBoard a (x' + u, y' + v) | u <- [0 .. 2], v <- [0 .. 2]]
  where
    x' = (3 * ((x - 1) `quot` 3)) + 1
    y' = (3 * ((y - 1) `quot` 3)) + 1

-- return the numbers that are available for a particular square
availableNums :: SudokuBoard -> (Int, Int) -> IO [Int]
availableNums a (x, y) = do
  r <- getRowNums a y
  c <- getColNums a x
  b <- getBoxNums a (x, y)
  return $ [0 .. 9] \\ (r `union` c `union` b)

-- aliases of read and write array that flatten the index
readBoard :: SudokuBoard -> (Int, Int) -> IO Int
readBoard a (x, y) = readArray a (x + 9 * (y - 1))

writeBoard :: SudokuBoard -> (Int, Int) -> Int -> IO ()
writeBoard a (x, y) e = writeArray a (x + 9 * (y - 1)) e

--------------------------------------------------------------------------------
examplePuzzles :: [[[Int]]]
examplePuzzles =
  [ [ [0, 6, 0, 1, 0, 4, 0, 5, 0],
      [0, 0, 8, 3, 0, 5, 6, 0, 0],
      [2, 0, 0, 0, 0, 0, 0, 0, 1],
      [8, 0, 0, 4, 0, 7, 0, 0, 6],
      [0, 0, 6, 0, 0, 0, 3, 0, 0],
      [7, 0, 0, 9, 0, 1, 0, 0, 4],
      [5, 0, 0, 0, 0, 0, 0, 0, 2],
      [0, 0, 7, 2, 0, 6, 9, 0, 0],
      [0, 4, 0, 5, 0, 8, 0, 7, 0]
    ],
    [ [0, 2, 0, 0, 9, 0, 0, 5, 3],
      [0, 0, 0, 0, 0, 0, 0, 0, 7],
      [8, 0, 0, 0, 5, 0, 9, 0, 2],
      [5, 3, 0, 0, 0, 8, 0, 0, 9],
      [0, 4, 8, 3, 6, 0, 0, 0, 0],
      [0, 7, 0, 2, 4, 0, 1, 0, 0],
      [0, 0, 0, 0, 8, 0, 0, 0, 1],
      [0, 0, 0, 0, 1, 0, 0, 0, 0],
      [2, 0, 0, 0, 0, 0, 0, 0, 0]
    ],
    [ [6, 7, 3, 0, 0, 0, 8, 1, 0],
      [0, 2, 0, 1, 6, 3, 0, 9, 0],
      [1, 0, 0, 0, 0, 0, 0, 0, 3],
      [0, 0, 4, 0, 0, 0, 0, 2, 8],
      [0, 0, 0, 0, 9, 0, 0, 3, 0],
      [0, 5, 0, 2, 0, 8, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0],
      [3, 0, 0, 0, 8, 1, 0, 0, 0],
      [0, 0, 0, 0, 0, 9, 0, 8, 0]
    ],
    [ [0, 5, 0, 0, 2, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 5, 0, 2],
      [0, 3, 1, 0, 5, 9, 4, 0, 8],
      [3, 0, 2, 1, 0, 0, 0, 0, 0],
      [1, 0, 0, 2, 6, 0, 7, 0, 4],
      [0, 0, 0, 4, 0, 3, 0, 0, 0],
      [0, 0, 0, 8, 7, 0, 0, 2, 0],
      [0, 0, 0, 5, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 4, 0, 0, 0]
    ]
  ]

altSolve :: ArithCircuit BN128 -> IntMap BN128 -> IntMap BN128
altSolve p inputs =
  evalArithCircuit
    (\w m -> IntMap.lookup (wireName w) m)
    (\w m -> IntMap.insert (wireName w) m)
    p
    inputs
