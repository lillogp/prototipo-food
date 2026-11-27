# Prove 045/046 (eseguite in transazione annullata, esito TEST_OK)
Coperto: voto solo su richiesta ritirata (cliente) / ritirata o non_presentato (commerciante); voto 1-10; motivi ammessi; un voto per parte;
tabelle non leggibili direttamente; voto nascosto finché l'altra parte non vota; valutazioni_cliente solo al commerciante; terzi non votano;
segnalazione unica per bersaglio; cliente non segnala "utente"; solo admin vede coda e applica provvedimenti; durata 1-365;
blocco_store: cliente non vede botteghe/prodotti/valutazioni, richiesta rifiutata ('bloccato'), avviso in notifications; revoca ripristina;
bottega_nascosta: sparisce ai clienti, resta al titolare, richieste rifiutate ('bottega_non_prenotabile'); valutazione_rimossa la toglie dal pubblico.
Script completo: vedi cronologia della sessione (DO block con set local role authenticated + raise exception 'TEST_OK').
