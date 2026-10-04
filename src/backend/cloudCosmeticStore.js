import { supabase } from './supabase.js';

const rpc = async (name, args) => {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data;
};

export const loadCosmeticStore = () => rpc('get_cosmetic_store');
export const purchaseCosmetic = ({ kind, id, requestId }) => rpc('purchase_cosmetic_store_item', {
  p_kind: kind,
  p_item_id: id,
  p_request_id: requestId
});
export const createFacetClaimCode = () => rpc('create_facet_claim_code');
export const saveCosmeticLoadout = equipment => rpc('set_my_cosmetic_loadout', { p_equipment: equipment });
