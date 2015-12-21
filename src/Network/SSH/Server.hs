{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.SSH.Server (

    Server(..)
  , ServerCredential
  , Client(..)
  , SessionEvent(..)
  , AuthResult(..)
  , sshServer
  , sayHello

  ) where

import           Network.SSH.Connection
import           Network.SSH.Messages
import           Network.SSH.Named
import           Network.SSH.Packet
import           Network.SSH.Rekey
import           Network.SSH.State

import           Control.Concurrent
import           Control.Monad (forever)
import qualified Control.Exception as X
import qualified Data.ByteString.Char8 as S
import           Data.IORef (writeIORef, readIORef)
import           Data.Serialize (runPutLazy)

-- Public API ------------------------------------------------------------------

data Server = Server
  { sAccept :: IO Client
  , sAuthenticationAlgs :: [ServerCredential]
  , sIdent :: SshIdent
  }

sshServer :: Server -> IO ()
sshServer sock = forever $
  do client <- sAccept sock

     forkIO $
       do let creds = sAuthenticationAlgs sock
          let prefs = allAlgsSshProposalPrefs
                { sshServerHostKeyAlgsPrefs = map nameOf creds }
          state <- initialState prefs ServerRole creds
          let v_s = sIdent sock
          v_c <- sayHello state client v_s
          writeIORef (sshIdents state) (v_s,v_c)
          initialKeyExchange client state

          -- Connection established!

          result <- handleAuthentication state client
          case result of
            Nothing -> send client state
                         (SshMsgDisconnect SshDiscNoMoreAuthMethodsAvailable
                                            "" "")
            Just (_user,svc) ->
              case svc of
                SshConnection -> runConnection client state
                                   connectionService
                _             -> return ()

       `X.finally` (do
         putStrLn "debug: main loop caught exception, closing client..."
         cClose client)


-- | Exchange identification information
sayHello :: SshState -> Client -> SshIdent -> IO SshIdent
sayHello state client v_us =
  do cPut client (runPutLazy $ putSshIdent v_us)
     -- parseFrom used because ident doesn't use the normal framing
     v_them <- parseFrom client (sshBuf state) getSshIdent
     debug $ "their SSH version: " ++ S.unpack (sshIdentString v_them)
     return v_them

handleAuthentication ::
  SshState -> Client -> IO (Maybe (S.ByteString, SshService))
handleAuthentication state client =
  do let notAvailable = send client state
                      $ SshMsgDisconnect SshDiscServiceNotAvailable "" ""

     Just session_id <- readIORef (sshSessionId state)
     req <- receive client state
     case req of

       SshMsgServiceRequest SshUserAuth ->
         do send client state (SshMsgServiceAccept SshUserAuth)
            authLoop

        where
         authLoop =
           do userReq <- receive client state
              case userReq of

                SshMsgUserAuthRequest user svc method ->
                  do result <- cAuthHandler client session_id user svc method

                     case result of

                       AuthAccepted ->
                         do send client state SshMsgUserAuthSuccess
                            return (Just (user, svc))

                       AuthPkOk keyAlg key ->
                         do send client state
                              (SshMsgUserAuthPkOk keyAlg key)
                            authLoop

                       AuthFailed [] ->
                         do send client state (SshMsgUserAuthFailure [] False)
                            return Nothing

                       AuthFailed ms ->
                         do send client state (SshMsgUserAuthFailure ms False)
                            authLoop


                _ -> notAvailable >> return Nothing

       _ -> notAvailable >> return Nothing
