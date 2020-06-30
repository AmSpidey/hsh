
module Utils where

import           Control.Exception              ( catch )
-- | The following 4 functions are adapted from the `extra` package.

-- | Like 'when', but where the test can be monadic.
whenM :: Monad m => m Bool -> m () -> m ()
whenM b t = ifM b t (pure ())

-- | Like 'unless', but where the test can be monadic.
unlessM :: Monad m => m Bool -> m () -> m ()
unlessM b = ifM b (pure ())

-- | Like @if@, but where the test can be monadic.
ifM :: Monad m => m Bool -> m a -> m a -> m a
ifM b t f = do b' <- b; if b' then t else f

-- | Like 'not', but where the test can be monadic.
notM :: Functor m => m Bool -> m Bool
notM = fmap not

-- like && but combining predicates.
(.&&) :: (a -> Bool) -> (a -> Bool) -> (a -> Bool)
f .&& g = \a -> f a && g a

-- taken from Data.List.Extra
unsnoc :: [a] -> Maybe ([a], a)
unsnoc [] = Nothing
unsnoc [x] = Just ([], x)
unsnoc (x:xs) = Just (x:a, b)
    where Just (a,b) = unsnoc xs

joinByBackslash :: [String] -> [String]
joinByBackslash [] = []
joinByBackslash (line:lines) =
    let res = joinByBackslash lines in -- TODO make it tail recursive
        case unsnoc line of
            Nothing -> res
            Just (l, '\\') -> case res of
                [] -> [l]
                l':ls' -> (l ++ l'):ls'
            _ -> line:res
